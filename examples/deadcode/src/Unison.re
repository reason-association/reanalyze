// Exmple of several DCE checks operating in unison

type break =
  | IfNeed
  | Never
  | Always;

type t = {
  break,
  doc: string,
};

type stack =
  | Empty
  | Cons(t, stack);

let group = (~break=IfNeed, doc) => {break, doc};

let rec fits = (w, stack) =>
  switch (stack) {
  | _ when w < 0 => false
  | Empty => true
  | Cons({doc}, stack) => fits(w - String.length(doc), stack)
  };

let rec toString = (~width, stack) => {
  switch (stack) {
  | Cons({break}, stack) =>
    switch (break) {
    | IfNeed =>
      (fits(width, stack) ? "fits" : "no")
      ++ (stack |> toString(~width=width - 1))
    | Never => "never"
    | Always => "always"
    }
  | Empty => ""
  };
};

toString(~width=80, Empty);
toString(~width=80, Cons(group(~break=Never, "abc"), Empty));
toString(~width=80, Cons(group(~break=Always, "d"), Empty));