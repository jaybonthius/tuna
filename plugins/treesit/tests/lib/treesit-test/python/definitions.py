# A comment before the docstring.
"""Module docstring after a comment."""
from __future__ import annotations
from . import sibling
from ..pkg.mod import thing as other
import collections.abc
from typing import Generic, Optional, TypeVar

K = TypeVar("K")
V = TypeVar("V")


class Box(Generic[K, V], collections.abc.Mapping):
    "A docstring in plain quotes."
    size: int = 0

    def get(self, key: K, default: V | None = None) -> Optional[V]:
        """Get."""
        "Not the first statement."
        if isinstance(key, (str, bytes)) or issubclass(type(key), Box):
            return default
        items: dict[str, list[K]] = {}
        f = lambda k, *rest: k
        return items.get(key, default)

    @classmethod
    def build(cls, n: int = 3) -> Box:
        x = cls(n)
        return cls.registry.get(x)

    @a.b.c
    def deep(self) -> collections.abc.Iterator[K]:
        yield from ()

    @pytest.mark.parametrize("x", [1])
    def p(self, x) -> None:
        text = f"{{literal}} {x!r}"
        raw = rb"\d+" + br'x'
        match x:
            case Box(size=0) | pkg.Shape():
                pass
        value = MappingProxyType(Box.DEFAULT)
        kind = float
        return str.upper(text) if callable(Box) else None
