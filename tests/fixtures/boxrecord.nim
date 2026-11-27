## Record types for tbox.nim's cross-module `with` and `boxAccessors` tests.
when defined(thetosTestLocal):
  import thetos/local
else:
  import thetos/box

type
  Base* = object of RootObj
    id*: int

  Record* = object of Base
    name*: string
    secret: int = 7

  Shape* = object
    hidden: int = 1
    case kind*: bool
    of true:
      radius*: float
    of false:
      side*: float

# Generated in this module: `secret` gets a getter that is not exported.
boxAccessors(Record)

proc secretOf*(b: Box[Record]): int =
  b.secret
