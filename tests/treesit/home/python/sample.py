#!/usr/bin/env python3
"""A sample of Python for Tuna's highlighting tests."""

from __future__ import annotations

import os
import os.path as osp
from collections import abc, defaultdict as dd
from . import sibling
from ..parent.module import Thing as Other
from typing import Generic, TypeVar, NewType, Optional

T = TypeVar("T")
UserId = NewType("UserId", int)
MAX_SIZE = 1_000
ratio = 0.5e-3
mask = 0xFF | 0o17 | 0b1010
imaginary = 3j
nothing = None
flags = True, False, Ellipsis, NotImplemented, ...
raw = r"\d+" + b"bytes" + rb"\x00"
escaped = "tab\there\nnew \u00e9 \x41 \\ \" \N{BULLET}"
joined = f"{MAX_SIZE!r:>10} {ratio:.2f} {{literal}} {nothing=}"
concat = ("one"
          "two")
multi = """line one
line two"""
a, *rest = [1, 2, 3]
(b, c) = d = 4, 5
[e, f] = 6, 7
counter: int = 0
counter += 1
if (n := len(rest)) > 1:
    pass


def plain(x, y=2, *args, z: int = 3, **kwargs) -> Optional[int]:
    """Docstring of a function."""
    "not a docstring"
    global counter
    nonlocal_name = lambda q, r=1: q + r
    squares = [i * i for i in range(10) if i % 2]
    table = {k: v for k, v in kwargs.items()}
    unique = {w for w in args}
    gen = (g for g in args)
    del table
    assert x is not None and y in args or not z, "message"
    return nonlocal_name(x, r=y)


async def fetch(url: str, *, timeout: float | None = None) -> bytes:
    async with open(url) as handle:
        async for chunk in handle:
            await chunk
    try:
        raise ValueError("bad") from None
    except (KeyError, IndexError) as error:
        print(error, file=None)
    except* OSError:
        pass
    else:
        yield 1
    finally:
        return b""


@dataclass
@functools.lru_cache(maxsize=None)
@app.route.get("/path")
class Point(Generic[T], metaclass=abc.ABCMeta):
    """Docstring of a class."""

    dimensions = 2
    _registry[0] = None
    __slots__ = ("x", "y")

    def __init__(self, x: float, y: float) -> None:
        self.x = x
        self.y: float = y
        super().__init__()

    @classmethod
    def origin(cls) -> "Point":
        return cls(0, 0)

    @property
    def norm(self):
        return (self.x ** 2 + self.y ** 2) ** 0.5

    def __repr__(self):
        return f"Point({self.x}, {self.y})"


read_text.__doc__ = "assigned through an attribute"
type Pair = tuple[int, int]
type(mock)._check = checker

match command.split():
    case [action]:
        pass
    case Point(x=0, y=0) | [_, *_]:
        pass
    case {"key": value, **others}:
        pass
    case str() as text if text:
        pass

while counter < 10:
    counter = counter + 1
    if counter == 5:
        continue
    elif counter > 8:
        break
for index in range(3):
    print(index, end="")
with open(os.devnull, "w") as sink, open("other") as other:
    sink.write("text")
isinstance(point, Point)
isinstance(point, (int, float))
issubclass(Point, object)
value = int(text) + float(ratio)
exec("code")
print(__name__, __file__, __doc__, point.__dict__, point.__class__)
items: list[dict[str, Optional[UserId]]] = []
pattern = re.compile(r"[a-z]+\.", re.IGNORECASE)
built = Point(1, 2)
