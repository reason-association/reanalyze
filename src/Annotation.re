type attributePayload =
  | BoolPayload(bool)
  | ConstructPayload(string)
  | FloatPayload(string)
  | IdentPayload(Longident.t)
  | IntPayload(string)
  | StringPayload(string)
  | TuplePayload(list(attributePayload))
  | UnrecognizedPayload;

let tagIsGenType = s => s == "genType" || s == "gentype";

let tagIsGenTypeImport = s => s == "genType.import" || s == "gentype.import";

let tagIsGenTypeOpaque = s => s == "genType.opaque" || s == "gentype.opaque";

let tagIsOneOfTheGenTypeAnnotations = s =>
  tagIsGenType(s) || tagIsGenTypeImport(s) || tagIsGenTypeOpaque(s);

let rec getAttributePayload = (checkText, attributes: Typedtree.attributes) => {
  let rec fromExpr = (expr: Parsetree.expression) =>
    switch (expr) {
    | {pexp_desc: Pexp_constant(Pconst_string(s, _))} =>
      Some(StringPayload(s))
    | {pexp_desc: Pexp_constant(Pconst_integer(n, _))} =>
      Some(IntPayload(n))
    | {pexp_desc: Pexp_constant(Pconst_float(s, _))} =>
      Some(FloatPayload(s))
    | {
        pexp_desc: Pexp_construct({txt: Lident(("true" | "false") as s)}, _),
        _,
      } =>
      Some(BoolPayload(s == "true"))
    | {pexp_desc: Pexp_construct({txt}, _), _} =>
      Some(ConstructPayload(txt |> Longident.flatten |> String.concat(".")))
    | {pexp_desc: Pexp_tuple(exprs)} =>
      let payloads =
        exprs
        |> List.rev
        |> List.fold_left(
             (payloads, expr) =>
               switch (expr |> fromExpr) {
               | Some(payload) => [payload, ...payloads]
               | None => payloads
               },
             [],
           );
      Some(TuplePayload(payloads));
    | {pexp_desc: Pexp_ident({txt})} => Some(IdentPayload(txt))
    | _ => None
    };
  switch (attributes) {
  | [] => None
  | [a, ...tl] =>
    let (txt, payload) = a |> Compat.getPayload;
    if (checkText(txt)) {
      switch (payload) {
      | PStr([]) => Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_eval(expr, _)}, ..._]) => expr |> fromExpr
      | PStr([{pstr_desc: Pstr_extension(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_value(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_primitive(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_type(_)}, ..._]) => Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_typext(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_exception(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_module(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_recmodule(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_modtype(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_open(_)}, ..._]) => Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_class(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_class_type(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_include(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PStr([{pstr_desc: Pstr_attribute(_)}, ..._]) =>
        Some(UnrecognizedPayload)
      | PPat(_) => Some(UnrecognizedPayload)
      | PSig(_) => Some(UnrecognizedPayload)
      | PTyp(_) => Some(UnrecognizedPayload)
      };
    } else {
      getAttributePayload(checkText, tl);
    };
  };
};

let hasAttribute = (checkText, attributes: Typedtree.attributes) =>
  getAttributePayload(checkText, attributes) != None;

let isOcamlSuppressDeadWarning = attributes => {
  switch (
    attributes
    |> getAttributePayload(x => x == "ocaml.warning" || x == "warning")
  ) {
  | Some(StringPayload(s)) =>
    switch (Str.search_forward(Str.regexp(Str.quote("-32")), s, 0)) {
    | _ => true
    | exception Not_found => false
    }
  | _ => false
  };
};
