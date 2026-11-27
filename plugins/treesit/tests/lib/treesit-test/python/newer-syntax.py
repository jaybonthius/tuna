#!/usr/bin/env python3
# A comment before the docstring.
r"""Module docstring with a prefix."""
from __future__ import annotations

import os, sys as _sys
from . import sibling
from ..pkg.mod import thing as other, Klass

__all__ = ["f", "Point"]
MAX_SIZE: int = 10
Pair = tuple[int, int]


def f[T](x: T, *args: int, key: str = "k", **kwargs: object) -> list[T] | None:
    """First statement: a docstring."""
    "A second bare string, not a docstring."
    global MAX_SIZE
    a, *rest = args
    (b := len(rest))
    total = sum(n for n in rest if (m := n) > 0)
    data = {k: v for k, v in kwargs.items()}
    s = rf"\d+{x!r:>{b}}" + u"u" + b"bytes".decode()
    t = f"{f'{a}'}"
    c = 0x1F + 1_000 + 2j
    if a is not None and key not in data:
        del data
    assert isinstance(x, (int, Klass)), "bad"
    return [x] if ... else None


class Point[T](Base, metaclass=Meta):
    __slots__ = ("x", "y")
    x: T

    @property
    def norm(self) -> float:
        return (self.x ** 2) ** .5

    @norm.setter
    def norm(self, value):
        nonlocal_value = value
        self._n = value

    @staticmethod
    def make(x=0, /, *, y=0) -> Point:
        return Point(x, y)

    @classmethod
    def build(cls, *a, **k):
        return cls(*a, **k)


async def run(paths: list[os.PathLike]) -> dict[str, bytes]:
    async with open_files(paths) as (fa, fb):
        out = {p: await read(p) async for p in paths}
    try:
        await go(lambda q=1, *r, **s: q)
    except* (ValueError, OSError) as eg:
        raise RuntimeError("x") from eg
    match out:
        case {"a": Point(x=0) as pt, **others}:
            pass
        case [first, *_] if first:
            yield from first
        case str() | bytes():
            pass
        case _:
            print(*paths, sep="\n", file=_sys.stderr)
    return NotImplemented


type Alias = dict[str, "Point"]
x = Ellipsis or ...
