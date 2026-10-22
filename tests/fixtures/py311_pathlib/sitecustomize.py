# emulate Python 3.11 pathlib: is_dir/is_file/exists re-raise errors other than ENOENT/ENOTDIR/EBADF/ELOOP
import os, errno, stat, pathlib
_IGN = (errno.ENOENT, errno.ENOTDIR, errno.EBADF, errno.ELOOP)
def _chk(self, pred):
    try:
        st = self.stat()
    except OSError as e:
        if getattr(e, "errno", None) not in _IGN:
            raise
        return False
    except ValueError:
        return False
    return pred(st.st_mode)
pathlib.Path.is_dir = lambda self: _chk(self, stat.S_ISDIR)
pathlib.Path.is_file = lambda self: _chk(self, stat.S_ISREG)
pathlib.Path.exists = lambda self: _chk(self, lambda m: True)
