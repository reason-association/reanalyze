// Generated by BUCKLESCRIPT, PLEASE EDIT WITH CARE


function group(breakOpt, doc) {
  var $$break = breakOpt !== undefined ? breakOpt : /* IfNeed */0;
  return {
          break: $$break,
          doc: doc
        };
}

function fits(_w, _stack) {
  while(true) {
    var stack = _stack;
    var w = _w;
    if (w < 0) {
      return false;
    }
    if (!stack) {
      return true;
    }
    _stack = stack[1];
    _w = w - stack[0].doc.length | 0;
    continue ;
  };
}

function toString(width, stack) {
  if (!stack) {
    return "";
  }
  var stack$1 = stack[1];
  switch (stack[0].break) {
    case /* IfNeed */0 :
        return (
                fits(width, stack$1) ? "fits" : "no"
              ) + toString(width - 1 | 0, stack$1);
    case /* Never */1 :
        return "never";
    case /* Always */2 :
        return "always";
    
  }
}

toString(80, /* Empty */0);

var $$break = /* Never */1;

toString(80, /* Cons */[
      {
        break: $$break,
        doc: "abc"
      },
      /* Empty */0
    ]);

var $$break$1 = /* Always */2;

toString(80, /* Cons */[
      {
        break: $$break$1,
        doc: "d"
      },
      /* Empty */0
    ]);

export {
  group ,
  fits ,
  toString ,
  
}
/*  Not a pure module */