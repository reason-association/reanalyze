(* Adapted from https://github.com/LexiFi/dead_code_analyzer *)

open DeadCommon

let checkAnyValueBindingWithNoSideEffects
    ({vb_pat = {pat_desc}; vb_expr = expr; vb_loc = loc} :
      Typedtree.value_binding) =
  match pat_desc with
  | Tpat_any when (not (SideEffects.checkExpr expr)) && not loc.loc_ghost ->
    let name = "_" |> Name.create ~isInterface:false in
    let currentModulePath = ModulePath.getCurrent () in
    let path = currentModulePath.path @ [!Common.currentModuleName] in
    name
    |> addValueDeclaration ~path ~loc ~moduleLoc:currentModulePath.loc
         ~sideEffects:false
  | _ -> ()

let collectValueBinding super self (vb : Typedtree.value_binding) =
  let oldCurrentBindings = !Current.bindings in
  let oldLastBinding = !Current.lastBinding in
  checkAnyValueBindingWithNoSideEffects vb;
  let loc =
    match vb.vb_pat.pat_desc with
    | Tpat_var (id, {loc = {loc_start; loc_ghost} as loc})
    | Tpat_alias
        ({pat_desc = Tpat_any}, id, {loc = {loc_start; loc_ghost} as loc})
      when (not loc_ghost) && not vb.vb_loc.loc_ghost ->
      let name = Ident.name id |> Name.create ~isInterface:false in
      let optionalArgs =
        vb.vb_expr.exp_type |> DeadOptionalArgs.fromTypeExpr
        |> OptionalArgs.fromList
      in
      let exists =
        match PosHash.find_opt decls loc_start with
        | Some {declKind = Value r} ->
          r.optionalArgs <- optionalArgs;
          true
        | _ -> false
      in
      let currentModulePath = ModulePath.getCurrent () in
      let path = currentModulePath.path @ [!Common.currentModuleName] in
      let isFirstClassModule =
        match vb.vb_expr.exp_type.desc with Tpackage _ -> true | _ -> false
      in
      (if (not exists) && not isFirstClassModule then
       (* This is never toplevel currently *)
       let isToplevel = oldLastBinding = Location.none in
       let sideEffects = SideEffects.checkExpr vb.vb_expr in
       name
       |> addValueDeclaration ~isToplevel ~loc ~moduleLoc:currentModulePath.loc
            ~optionalArgs ~path ~sideEffects);
      (match PosHash.find_opt decls loc_start with
      | None -> ()
      | Some decl ->
        (* Value bindings contain the correct location for the entire declaration: update final position.
           The previous value was taken from the signature, which only has positions for the id. *)
        let declKind =
          match decl.declKind with
          | Value vk ->
            DeclKind.Value
              {vk with sideEffects = SideEffects.checkExpr vb.vb_expr}
          | dk -> dk
        in
        PosHash.replace decls loc_start
          {
            decl with
            declKind;
            posEnd = vb.vb_loc.loc_end;
            posStart = vb.vb_loc.loc_start;
          });
      loc
    | _ -> !Current.lastBinding
  in
  Current.bindings := PosSet.add loc.loc_start !Current.bindings;
  Current.lastBinding := loc;
  let r = super.Tast_mapper.value_binding self vb in
  Current.bindings := oldCurrentBindings;
  Current.lastBinding := oldLastBinding;
  r

let processOptionalArgs ~expType ~(locFrom : Location.t) ~locTo ~path args =
  if expType |> DeadOptionalArgs.hasOptionalArgs then (
    let supplied = ref [] in
    let suppliedMaybe = ref [] in
    args
    |> List.iter (fun (lbl, arg) ->
           let argIsSupplied =
             match arg with
             | Some
                 {
                   Typedtree.exp_desc =
                     Texp_construct (_, {cstr_name = "Some"}, _);
                 } ->
               Some true
             | Some
                 {
                   Typedtree.exp_desc =
                     Texp_construct (_, {cstr_name = "None"}, _);
                 } ->
               Some false
             | Some _ -> None
             | None -> Some false
           in
           match lbl with
           | Asttypes.Optional s when not locFrom.loc_ghost ->
             if argIsSupplied <> Some false then supplied := s :: !supplied;
             if argIsSupplied = None then suppliedMaybe := s :: !suppliedMaybe
           | _ -> ());
    (!supplied, !suppliedMaybe)
    |> DeadOptionalArgs.addReferences ~locFrom ~locTo ~path)

let collectExpr super self (e : Typedtree.expression) =
  let locFrom = e.exp_loc in
  (match e.exp_desc with
  | Texp_ident (_path, _, {Types.val_loc = {loc_ghost = false; _} as locTo}) ->
    if locFrom = locTo && _path |> Path.name = "emptyArray" then (
      (* Work around lowercase jsx with no children producing an artifact `emptyArray`
         which is called from its own location as many things are generated on the same location. *)
      if !Common.Cli.debug then
        Log_.item "addDummyReference %s --> %s@."
          (Location.none.loc_start |> posToString)
          (locTo.loc_start |> posToString);
      ValueReferences.add locTo.loc_start Location.none.loc_start)
    else addValueReference ~addFileReference:true ~locFrom ~locTo
  | Texp_apply
      ( {
          exp_desc =
            Texp_ident
              (path, _, {Types.val_loc = {loc_ghost = false; _} as locTo});
          exp_type;
        },
        args ) ->
    args
    |> processOptionalArgs ~expType:exp_type
         ~locFrom:(locFrom : Location.t)
         ~locTo ~path
  | Texp_let
      ( (* generated for functions with optional args *)
      Nonrecursive,
        [
          {
            vb_pat = {pat_desc = Tpat_var (idArg, _)};
            vb_expr =
              {
                exp_desc =
                  Texp_ident
                    (path, _, {Types.val_loc = {loc_ghost = false; _} as locTo});
                exp_type;
              };
          };
        ],
        {
          exp_desc =
            Texp_function
              {
                cases =
                  [
                    {
                      c_lhs = {pat_desc = Tpat_var (etaArg, _)};
                      c_rhs =
                        {
                          exp_desc =
                            Texp_apply
                              ({exp_desc = Texp_ident (idArg2, _, _)}, args);
                        };
                    };
                  ];
              };
        } )
    when Ident.name idArg = "arg"
         && Ident.name etaArg = "eta"
         && Path.name idArg2 = "arg" ->
    args
    |> processOptionalArgs ~expType:exp_type
         ~locFrom:(locFrom : Location.t)
         ~locTo ~path
  | Texp_field
      (_, _, {lbl_loc = {Location.loc_start = posTo; loc_ghost = false}; _}) ->
    if !Config.analyzeTypes then
      DeadType.addTypeReference ~posTo ~posFrom:locFrom.loc_start
  | Texp_construct
      ( _,
        {cstr_loc = {Location.loc_start = posTo; loc_ghost} as locTo; cstr_tag},
        _ ) ->
    (match cstr_tag with
    | Cstr_extension (path, _) ->
      path |> DeadException.markAsUsed ~locFrom ~locTo
    | _ -> ());
    if !Config.analyzeTypes && not loc_ghost then
      DeadType.addTypeReference ~posTo ~posFrom:locFrom.loc_start
  | _ -> ());
  super.Tast_mapper.expr self e

(*
  type k. is a locally abstract type
  https://caml.inria.fr/pub/docs/manual-ocaml/locallyabstract.html
  it is required because in ocaml >= 4.11 Typedtree.pattern and ADT is converted
  in a GADT
  https://github.com/ocaml/ocaml/commit/312253ce822c32740349e572498575cf2a82ee96
  in short: all branches of pattern matches aren't the same type.
  With this annotation we declare a new type for each branch to allow the
  function to be typed.
  *)
let collectPattern :
    type k. _ -> _ -> k Compat.generalPattern -> k Compat.generalPattern =
 fun super self pat ->
  let posFrom = pat.Typedtree.pat_loc.loc_start in
  (match pat.pat_desc with
  | Typedtree.Tpat_record (cases, _clodsedFlag) ->
    cases
    |> List.iter (fun (_loc, {Types.lbl_loc = {loc_start = posTo}}, _pat) ->
           if !Config.analyzeTypes then
             DeadType.addTypeReference ~posFrom ~posTo)
  | _ -> ());
  super.Tast_mapper.pat self pat

let rec getSignature (moduleType : Types.module_type) =
  match moduleType with
  | Mty_signature signature -> signature
  | Mty_functor _ -> (
    match moduleType |> Compat.getMtyFunctorModuleType with
    | Some (_, mt) -> getSignature mt
    | _ -> [])
  | _ -> []

let rec processSignatureItem ~doTypes ~doValues ~moduleLoc ~path
    (si : Types.signature_item) =
  match si with
  | Sig_type _ when doTypes ->
    let id, t = si |> Compat.getSigType in
    if !Config.analyzeTypes then
      DeadType.addDeclaration ~typeId:id ~typeKind:t.type_kind
  | Sig_value _ when doValues ->
    let id, loc, kind, valType = si |> Compat.getSigValue in
    if not loc.Location.loc_ghost then
      let isPrimitive = match kind with Val_prim _ -> true | _ -> false in
      if (not isPrimitive) || Config.analyzeExternals then
        let optionalArgs =
          valType |> DeadOptionalArgs.fromTypeExpr |> OptionalArgs.fromList
        in
        Ident.name id
        |> Name.create ~isInterface:false
        |> addValueDeclaration ~loc ~moduleLoc ~optionalArgs ~path
             ~sideEffects:false
  | Sig_module _ | Sig_modtype _ -> (
    match si |> Compat.getSigModuleModtype with
    | Some (id, moduleType, moduleLoc) ->
      let collect = match si with Sig_modtype _ -> false | _ -> true in
      if collect then
        getSignature moduleType
        |> List.iter
             (processSignatureItem ~doTypes ~doValues ~moduleLoc
                ~path:((id |> Ident.name |> Name.create) :: path))
    | None -> ())
  | _ -> ()

(* Traverse the AST *)
let traverseStructure ~doTypes ~doExternals =
  let super = Tast_mapper.default in
  let expr self e = e |> collectExpr super self in
  let pat self p = p |> collectPattern super self in
  let value_binding self vb = vb |> collectValueBinding super self in
  let structure_item self (structureItem : Typedtree.structure_item) =
    let oldModulePath = ModulePath.getCurrent () in
    (match structureItem.str_desc with
    | Tstr_module {mb_expr; mb_id; mb_loc} -> (
      let hasInterface =
        match mb_expr.mod_desc with Tmod_constraint _ -> true | _ -> false
      in
      ModulePath.setCurrent
        {
          oldModulePath with
          loc = mb_loc;
          path =
            (mb_id |> Compat.moduleIdName |> Name.create) :: oldModulePath.path;
        };
      if hasInterface then
        match mb_expr.mod_type with
        | Mty_signature signature ->
          signature
          |> List.iter
               (processSignatureItem ~doTypes ~doValues:false
                  ~moduleLoc:mb_expr.mod_loc
                  ~path:
                    ((ModulePath.getCurrent ()).path
                    @ [!Common.currentModuleName]))
        | _ -> ())
    | Tstr_primitive vd when doExternals && Config.analyzeExternals ->
      let currentModulePath = ModulePath.getCurrent () in
      let path = currentModulePath.path @ [!Common.currentModuleName] in
      let exists =
        match PosHash.find_opt decls vd.val_loc.loc_start with
        | Some {declKind = Value _} -> true
        | _ -> false
      in
      let id = vd.val_id |> Ident.name in
      if
        (not exists) && id <> "unsafe_expr"
        (* see https://github.com/BuckleScript/bucklescript/issues/4532 *)
      then
        id
        |> Name.create ~isInterface:false
        |> addValueDeclaration ~path ~loc:vd.val_loc
             ~moduleLoc:currentModulePath.loc ~sideEffects:false
    | Tstr_type (_recFlag, typeDeclarations) when doTypes ->
      if !Config.analyzeTypes then
        typeDeclarations
        |> List.iter (fun (typeDeclaration : Typedtree.type_declaration) ->
               DeadType.addDeclaration ~typeId:typeDeclaration.typ_id
                 ~typeKind:typeDeclaration.typ_type.type_kind)
    | Tstr_include {incl_mod; incl_type} -> (
      match incl_mod.mod_desc with
      | Tmod_ident (_path, _lid) ->
        let currentPath =
          (ModulePath.getCurrent ()).path @ [!Common.currentModuleName]
        in
        incl_type
        |> List.iter
             (processSignatureItem ~doTypes
                ~doValues:false (* TODO: also values? *)
                ~moduleLoc:incl_mod.mod_loc ~path:currentPath)
      | _ -> ())
    | Tstr_exception _ -> (
      match structureItem.str_desc |> Compat.tstrExceptionGet with
      | Some (id, loc) ->
        let path =
          (ModulePath.getCurrent ()).path @ [!Common.currentModuleName]
        in
        let name = id |> Ident.name |> Name.create in
        name |> DeadException.add ~path ~loc ~strLoc:structureItem.str_loc
      | None -> ())
    | _ -> ());
    let result = super.structure_item self structureItem in
    ModulePath.setCurrent oldModulePath;
    result
  in
  let open Tast_mapper in
  {super with expr; pat; structure_item; value_binding}

(* Merge a location's references to another one's *)
let processValueDependency
    ( ({
         val_loc =
           {loc_start = {pos_fname = fnTo} as posTo; loc_ghost = ghost1} as
           locTo;
       } :
        Types.value_description),
      ({
         val_loc =
           {loc_start = {pos_fname = fnFrom} as posFrom; loc_ghost = ghost2} as
           locFrom;
       } :
        Types.value_description) ) =
  if (not ghost1) && (not ghost2) && posTo <> posFrom then (
    let addFileReference = fileIsImplementationOf fnTo fnFrom in
    addValueReference ~addFileReference ~locFrom ~locTo;
    DeadOptionalArgs.addFunctionReference ~locFrom ~locTo)

let processStructure ~cmt_value_dependencies ~doTypes ~doExternals
    (structure : Typedtree.structure) =
  let traverseStructure = traverseStructure ~doTypes ~doExternals in
  structure |> traverseStructure.structure traverseStructure |> ignore;
  let valueDependencies = cmt_value_dependencies |> List.rev in
  valueDependencies |> List.iter processValueDependency