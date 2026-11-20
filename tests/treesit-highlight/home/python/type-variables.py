from typing import TypeVar
T = TypeVar("T")
KT = TypeVar("KT")


def first(xs: list[T], k: KT) -> T:
    return xs[0]


@a.b.c
def g():
    pass


@pytest.mark.parametrize("x", [1])
def h(x):
    pass


class A:
    @classmethod
    def make(cls, n=None):
        return cls.registry.get(n)
