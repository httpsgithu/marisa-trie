from __future__ import unicode_literals
#from cython cimport view
#cimport cpython.array
#import array
#from libc.stdlib cimport free, malloc

from std_iostream cimport stringstream, istream, ostream
cimport keyset
cimport key
cimport query
cimport agent
cimport trie
cimport iostream
cimport base


DEFAULT_CACHE = base.MARISA_DEFAULT_CACHE
HUGE_CACHE = base.MARISA_HUGE_CACHE
LARGE_CACHE = base.MARISA_LARGE_CACHE
NORMAL_CACHE = base.MARISA_NORMAL_CACHE
SMALL_CACHE = base.MARISA_SMALL_CACHE
TINY_CACHE = base.MARISA_TINY_CACHE
DEFAULT_CACHE = base.MARISA_DEFAULT_CACHE

MIN_NUM_TRIES = base.MARISA_MIN_NUM_TRIES
MAX_NUM_TRIES = base.MARISA_MAX_NUM_TRIES
DEFAULT_NUM_TRIES = base.MARISA_DEFAULT_NUM_TRIES

# MARISA_TEXT_TAIL merges last labels as zero-terminated strings. So, it is
# available if and only if the last labels do not contain a NULL character.
# If MARISA_TEXT_TAIL is specified and a NULL character exists in the last
# labels, the setting is automatically switched to MARISA_BINARY_TAIL.
TEXT_TAIL = base.MARISA_TEXT_TAIL

# MARISA_BINARY_TAIL also merges last labels but as byte sequences. It uses
# a bit vector to detect the end of a sequence, instead of NULL characters.
# So, MARISA_BINARY_TAIL requires a larger space if the average length of
# labels is greater than 8.
BINARY_TAIL = base.MARISA_BINARY_TAIL
DEFAULT_TAIL = base.MARISA_DEFAULT_TAIL


# MARISA_LABEL_ORDER arranges nodes in ascending label order.
# MARISA_LABEL_ORDER is useful if an application needs to predict keys in
# label order.
LABEL_ORDER = base.MARISA_LABEL_ORDER

# MARISA_WEIGHT_ORDER arranges nodes in descending weight order.
# MARISA_WEIGHT_ORDER is generally a better choice because it enables faster
# matching.
WEIGHT_ORDER = base.MARISA_WEIGHT_ORDER
DEFAULT_ORDER = base.MARISA_DEFAULT_ORDER


cdef class _Trie:
    """
    Base MARISA-trie wrapper.
    It can store unicode keys and assigns an unque ID to each key.
    """

    cdef trie.Trie* _trie

    def __init__(self, arg=None, num_tries=DEFAULT_NUM_TRIES, binary=False,
                        cache_size=DEFAULT_CACHE, order=DEFAULT_ORDER):
        """
        ``arg`` must be an iterable with unicode keys or None
        if you're going to load a trie later.
        """

        if self._trie:
            return
        self._trie = new trie.Trie()

        byte_keys = (key.encode('utf8') for key in sorted(arg or []))
        self._build(
            byte_keys,
            num_tries=num_tries,
            binary=binary,
            cache_size=cache_size,
            order=order
        )


    def __dealloc__(self):
        if self._trie:
            del self._trie


    def _config_flags(self, num_tries=DEFAULT_NUM_TRIES, binary=False,
                            cache_size=DEFAULT_CACHE, order=DEFAULT_ORDER):

        if not MIN_NUM_TRIES <= num_tries <= MAX_NUM_TRIES:
            raise ValueError("num_tries (which is %d) must be between between %d and %d" % (num_tries, MIN_NUM_TRIES, MAX_NUM_TRIES))

        binary_flag = BINARY_TAIL if binary else TEXT_TAIL
        return num_tries | binary_flag | cache_size | order


    def _build(self, byte_keys, **options):
        """
        Builds the trie using values from ``byte_keys`` iterable.
        """
        cdef char* data
        cdef keyset.Keyset *ks = new keyset.Keyset()

        try:
            for key in byte_keys:
                data = key
                ks.push_back(data, len(key))
            self._trie.build(ks[0], self._config_flags(**options))
        finally:
            del ks

    def __len__(self):
        return self._trie.num_keys()

    def __contains__(self, unicode key):
        cdef bytes _key = key.encode('utf8')
        return self._contains(_key)

    cdef bint _contains(self, bytes key):
        cdef agent.Agent ag
        ag.set_query(key)
        return self._trie.lookup(ag)

    def read(self, f):
        """
        Reads a trie from an open file object.

        Works only with "real" disk-based file objects,
        file-like objects are not supported.
        """
        self._trie.read(f.fileno())

    def write(self, f):
        """
        Reads a trie to an open file object.

        Works only with "real" disk-based file objects,
        file-like objects are not supported.
        """
        self._trie.write(f.fileno())

    def save(self, path):
        """ Saves trie to a file. """
        with open(path, 'w') as f:
            self.write(f)

    def load(self, path):
        """ Loads trie from a file. """
        with open(path, 'r') as f:
            self.read(f)

    cpdef bytes tobytes(self) except +:
        """
        Returns raw trie content as bytes.
        """
        cdef stringstream stream
        iostream.write((<ostream *> &stream)[0], self._trie[0])
        cdef bytes res = stream.str()
        return res

    cpdef frombytes(self, bytes data) except +:
        """
        Loads trie from bytes ``data``.
        """
        cdef stringstream* stream = new stringstream(data)
        try:
            iostream.read((<istream *> stream)[0], self._trie)
        finally:
            del stream
        return self


    def __reduce__(self): # pickling support
        return self.__class__, tuple(), self.tobytes()

    def __setstate__(self, state): # pickling support
        self.frombytes(state)


    def mmap(self, path):
        """
        Mmaps trie to a file; this allows lookups without loading full
        trie to memory.
        """
        import sys
        str_path = path.encode(sys.getfilesystemencoding())
        cdef char* c_path = str_path
        self._trie.mmap(c_path)

    def iter_prefixes(self, unicode key):
        """
        Returns an iterator of all prefixes of a given key.
        """
        cdef agent.Agent ag
        cdef bytes b_prefix

        cdef bytes b_key = key.encode('utf8')
        ag.set_query(b_key)

        while self._trie.common_prefix_search(ag):
            b_prefix = ag.key().ptr()[:ag.key().length()]
            yield b_prefix.decode('utf8')

    def prefixes(self, unicode key):
        """
        Returns a list with all prefixes of a given key.
        """

        # this an inlined version of ``list(self.iter_prefixes(key))``

        cdef agent.Agent ag
        cdef bytes b_prefix
        cdef list res = []

        cdef bytes b_key = key.encode('utf8')
        ag.set_query(b_key)

        while self._trie.common_prefix_search(ag):
            b_prefix = ag.key().ptr()[:ag.key().length()]
            res.append(b_prefix.decode('utf8'))
        return res

    def iterkeys(self, unicode prefix=""):
        """
        Returns an iterator over keys that have a prefix ``prefix``.
        """
        cdef agent.Agent ag
        cdef bytes b_key
        cdef bytes b_prefix = prefix.encode('utf8')
        ag.set_query(b_prefix)

        while self._trie.predictive_search(ag):
            b_key = ag.key().ptr()[:ag.key().length()]
            yield b_key.decode('utf8')

    cpdef list keys(self, unicode prefix=""):
        """
        Returns a list with all keys with a prefix ``prefix``.
        """
        # non-generator inlined version of iterkeys()
        cdef list res = []
        cdef bytes b_key

        cdef bytes b_prefix = prefix.encode('utf8')
        cdef agent.Agent ag
        ag.set_query(b_prefix)

        while self._trie.predictive_search(ag):
            b_key = ag.key().ptr()[:ag.key().length()]
            res.append(b_key.decode('utf8'))

        return res


# This symbol is not allowed in utf8 so it is safe to use
# as a separator between utf8-encoded string and binary payload.
DEF _VALUE_SEPARATOR = b'\xff'

cdef class BytesTrie(_Trie):
    """
    Trie that store extra binary payload in keys;
    there may be several payloads for the same key.

    In other words, this class implements read-only Trie-based
    {unicode -> list of bytes objects} mapping.
    """

    def __init__(self, arg=None, **options):
        """
        ``arg`` must be an iterable of tuples (unicode_key, bytes_payload).
        """
        super(BytesTrie, self).__init__()
        if arg is None:
            arg = []
        byte_keys = (self._raw_key(d[0], d[1]) for d in sorted(arg))
        self._build(byte_keys, **options)


    cpdef bytes _raw_key(self, unicode key, bytes payload):
        return key.encode('utf8') + _VALUE_SEPARATOR + payload

    cdef bint _contains(self, bytes key):
        cdef agent.Agent ag
        cdef bytes _key = key + _VALUE_SEPARATOR
        ag.set_query(_key)
        return self._trie.predictive_search(ag)


    def __getitem__(self, key):
        cdef list res

        if isinstance(key, unicode):
            res = self.get_value(key)
        else:
            res = self.b_get_value(key)

        if not res:
            raise KeyError(key)
        return res


    cpdef list get_value(self, unicode key):
        """
        Returns a list of payloads (as byte objects) for a given unicode key.
        """
        cdef bytes b_key = key.encode('utf8')
        return self.b_get_value(b_key)


    cpdef list b_get_value(self, bytes key):
        """
        Returns a list of payloads (as byte objects) for a given utf8-encoded key.
        """
        cdef list res = []
        cdef bytes value
        cdef bytes b_prefix = key + _VALUE_SEPARATOR
        cdef int prefix_len = len(b_prefix)

        cdef agent.Agent ag
        ag.set_query(b_prefix)

        while self._trie.predictive_search(ag):
            value = ag.key().ptr()[prefix_len:ag.key().length()]
            res.append(value)

        return res


    cpdef list items(self, unicode prefix=""):
        cdef bytes b_prefix = prefix.encode('utf8')
        cdef bytes key, raw_key, value
        cdef list res = []

        cdef agent.Agent ag
        ag.set_query(b_prefix)

        while self._trie.predictive_search(ag):
            raw_key = ag.key().ptr()[:ag.key().length()]
            key, value = raw_key.split(_VALUE_SEPARATOR, 1)
            res.append(
                (key.decode('utf8'), value)
            )
        return res

    cpdef list keys(self, unicode prefix=""):
        items = self.items(prefix)
        if not items:
            return []
        keys, values = zip(*items)
        return list(keys)



cdef class Trie(_Trie):
    """
    This trie stores unicode keys and assigns an unque ID to each key.
    """

    cpdef int key_id(self, unicode key) except -1:
        """
        Returns unique auto-generated key index for a ``key``.
        Raises KeyError if key is not in this trie.
        """
        cdef bytes _key = key.encode('utf8')
        cdef int res = self._key_id(_key)
        if res == -1:
            raise KeyError(key)
        return res

    cpdef unicode restore_key(self, int index):
        """
        Returns a key given its index (obtained by ``key_id`` method).
        """
        cdef agent.Agent ag
        ag.set_query(index)
        try:
            self._trie.reverse_lookup(ag)
        except KeyError:
            raise KeyError(index)
        cdef bytes _key = ag.key().ptr()
        return _key.decode('utf8')

    cdef int _key_id(self, char* key):
        cdef bint res
        cdef agent.Agent ag
        ag.set_query(key)
        res = self._trie.lookup(ag)
        if not res:
            return -1
        return ag.key().id()




#cdef class IntTrie(Trie):
#    """
#    This IntTrie can store unicode keys and have arbitrary integers as values.
#    """
#    cdef int* _int_values
#
#    def build(self, data_dict, num_tries=Trie.DEFAULT_NUM_TRIES, binary=False, cache_size=Trie.DEFAULT_CACHE, order=Trie.DEFAULT_ORDER):
#
#        if data_dict is None:
#            data_dict = {}
#
#        super(IntTrie, self).build(data_dict.keys(), num_tries, binary, cache_size, order)
#
#        self._int_values = <int*>malloc(len(self) * sizeof(int))
#        for key in data_dict:
#            self._int_values[self.key_id(key)] = data_dict[key]
#
#        return self
#
#    def __cinit__(self):
#        self._int_values = NULL
#
#    def __dealloc__(self):
#        if self._int_values:
#            free(<void*>self._int_values)
#
#
##    cpdef bytes dumps(self) except +:
##        cdef bytes data = super(IntTrie, self).dumps()
##        return data + self._int_values
##
#
#    def mmap(self, path):
#        raise NotImplementedError()
#
#    def __getitem__(self, unicode key):
#        cdef bytes b_key = key.encode('utf8')
#        return self._getitem(b_key)
#
#    def __setitem__(self, unicode key, int value):
#        cdef bytes b_key = key.encode('utf8')
#        if not self._setitem(b_key, value):
#            raise KeyError("Insertion is not supported; key=" + key)
#
#    cdef int _getitem(self, char* key):
#        cdef int index = self._key_id(key)
#        return self._int_values[index]
#
#    cdef bint _setitem(self, char* key, int value):
#        cdef int index = self._key_id(key)
#        if index == -1:
#            return False
#        self._int_values[index] = value
#        return True
#