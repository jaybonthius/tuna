import os
import os.path as osp
from pathlib import Path


class Store(Base):
    """A store."""

    def load(self, name: str) -> None:
        if not os.path.exists(name):
            raise ValueError(f"no {name}\n")
        print(len(name), True, None)
        return self.cache.get(name)
