/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Internal os_log argument codec. Clang's descriptor/size ABI is described in
 * clang/AST/OSLog.h; range records follow XNU libkern/os/log_encode_types.h.
 * All pointer reads are delegated to a bounds-checked capture source. Rendering
 * accepts only serialized values, never a va_list or an argument pointer.
 */
#include <sys/types.h>

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <link.h>
#include <locale.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <xlocale.h>

#include "oslog_codec.h"

#define MAX_ITEMS 255
#define PRIVATE	  1
#define PUBLIC	  2
#define SCALAR	  0
#define COUNT	  1
#define STRING	  2
#define WIDE	  5
#define MAX_FIELD 4096
struct command {
	const unsigned char *data;
	unsigned char type, flags, size;
};
static uint16_t
get16(const unsigned char *p)
{
	return ((uint16_t)p[0] | (uint16_t)p[1] << 8);
}
static void
put16(unsigned char *p, uint16_t n)
{
	p[0] = n;
	p[1] = n >> 8;
}
static bool
valid_flags(unsigned f)
{
	return (f == 0 || f == 1 || f == 2 || f == 5);
}
static bool
scalar_size(unsigned n)
{
	return (n == 1 || n == 2 || n == 4 || n == 8 || n == 16);
}
static int
commands(const unsigned char *p, size_t n, struct command *items, size_t *end,
    bool flattened)
{
	size_t off = 2;
	unsigned i, summary = 0;

	if (p == NULL || n < 2 || (p[0] & ~3) != 0)
		return (EINVAL);
	for (i = 0; i < p[1]; i++) {
		struct command *cmd = &items[i];
		if (off > n || n - off < 2)
			return (EINVAL);
		cmd->flags = p[off] & 15;
		cmd->type = p[off] >> 4;
		cmd->size = p[off + 1];
		off += 2;
		if (!valid_flags(cmd->flags) || cmd->size > n - off)
			return (EINVAL);
		cmd->data = p + off;
		off += cmd->size;
		if (cmd->flags & PRIVATE)
			summary |= 1;
		if (cmd->type != SCALAR)
			summary |= 2;
		switch (cmd->type) {
		case SCALAR:
			if (!scalar_size(cmd->size) ||
			    (flattened && (cmd->flags & PRIVATE) &&
				cmd->size != 4))
				return (EINVAL);
			break;
		case COUNT:
			if (cmd->size != 4 || i + 1 == p[1])
				return (EINVAL);
			break;
		case STRING:
		case WIDE:
			if (cmd->size != (flattened ? 4 : sizeof(uintptr_t)))
				return (EINVAL);
			break;
		default:
			return (ENOTSUP);
		}
	}
	for (i = 0; i < p[1]; i++)
		if (items[i].type == COUNT && items[i + 1].type != STRING &&
		    items[i + 1].type != WIDE)
			return (EINVAL);
	if (p[0] != summary || (!flattened && off != n))
		return (EINVAL);
	*end = off;
	return (0);
}
int
__oslog_codec_literal(const void *p)
{
	struct dl_phdr_info info;
	uintptr_t addr = (uintptr_t)p, start;
	unsigned i;

	/* Query lifetime first: a non-dlopen image is permanent. Both rtld
	 * queries take read locks; never use dl_iterate_phdr's write lock here.
	 */
	if (p == NULL || _rtld_is_dlopened((void *)(uintptr_t)p) != 0 ||
	    !_rtld_addr_phdr(p, &info))
		return (0);
	for (i = 0; i < info.dlpi_phnum; i++) {
		const Elf_Phdr *ph = &info.dlpi_phdr[i];
		if (ph->p_type != PT_LOAD || !(ph->p_flags & PF_R) ||
		    (ph->p_flags & PF_W) ||
		    ph->p_vaddr > UINTPTR_MAX - info.dlpi_addr)
			continue;
		start = info.dlpi_addr + ph->p_vaddr;
		if (addr >= start && addr - start < ph->p_memsz)
			return (1);
	}
	return (0);
}
/* Return the longest complete UTF-8 prefix; never manufacture U+FFFD. */
static size_t
utf8_prefix(const unsigned char *s, size_t n)
{
	size_t i = 0, j, k;
	unsigned c, next;

	while (i < n) {
		c = s[i];
		if (c < 0x80) {
			i++;
			continue;
		}
		if (c >= 0xc2 && c <= 0xdf)
			k = 2;
		else if (c >= 0xe0 && c <= 0xef)
			k = 3;
		else if (c >= 0xf0 && c <= 0xf4)
			k = 4;
		else
			break;
		if (k > n - i)
			break;
		next = s[i + 1];
		if ((c == 0xe0 && next < 0xa0) || (c == 0xed && next >= 0xa0) ||
		    (c == 0xf0 && next < 0x90) || (c == 0xf4 && next >= 0x90))
			break;
		for (j = 1; j < k; j++)
			if ((s[i + j] & 0xc0) != 0x80)
				break;
		if (j != k)
			break;
		i += k;
	}
	return (i);
}
int
__oslog_codec_flatten(const unsigned char *input, size_t n, unsigned type,
    __oslog_byte_reader reader, void *context, unsigned char *out, size_t cap,
    size_t *used)
{
	struct command items[MAX_ITEMS];
	unsigned char meta[__OSLOG_CODEC_FAULT_CAP],
	    data[__OSLOG_CODEC_FAULT_CAP];
	size_t end, m = 0, d = 0, limit, size, room, len, kept, i;
	unsigned count = 0, flags = 0, f;
	int error, precision = -1;
	uintptr_t pointer;
	bool secret, truncated, terminated;

	if (used == NULL)
		return (EINVAL);
	*used = 0;
	if (out == NULL ||
	    (type != 0 && type != 1 && type != 2 && type != 16 && type != 17))
		return (EINVAL);
	limit = type == 17 ? __OSLOG_CODEC_FAULT_CAP : __OSLOG_CODEC_CAP;
	if (cap < limit)
		return (ENOSPC);
	if ((error = commands(input, n, items, &end, false)) != 0)
		return (error);
	for (i = 0; i < input[1]; i++) {
		struct command *cmd = &items[i];
		f = cmd->flags;
		secret = (f & PRIVATE) != 0;
		if (cmd->type == COUNT)
			memcpy(&precision, cmd->data, sizeof(precision));
		if (cmd->type == STRING || cmd->type == WIDE) {
			memcpy(&pointer, cmd->data, sizeof(pointer));
			if (f == 0 && pointer != 0 &&
			    !__oslog_codec_literal((void *)pointer)) {
				f = PRIVATE;
				secret = true;
			}
			size = 4;
		} else
			size = secret ? 4 : cmd->size;
		/* Charge each item and its data now. Do not reserve future
		 * items. */
		if (size + 2 > limit - 2 - m - d)
			break;
		meta[m++] = (cmd->type << 4) | f;
		meta[m++] = size;
		if (secret) {
			memset(meta + m, 0, size);
			flags |= 1;
		} else if (cmd->type == STRING || cmd->type == WIDE) {
			room = limit - 2 - m - size - d;
			if (room == 0 && precision != 0) {
				m -= 2;
				break;
			}
			len = 0;
			truncated = false;
			while (len < room) {
				unsigned char ch;
				if (precision >= 0 && len == (size_t)precision)
					break;
				if (pointer == 0)
					ch = ((const unsigned char
						*)"(null)")[len];
				else {
					if (reader == NULL)
						return (EINVAL);
					if ((error = reader(context, pointer,
						 len, &ch)) != 0)
						return (error);
				}
				if (ch == 0)
					break;
				data[d + len++] = ch;
			}
			if (len == room && precision != 0) {
				len--;
				truncated = true;
			}
			kept = truncated ? utf8_prefix(data + d, len) : len;
			terminated = truncated || precision < 0;
			if (terminated)
				data[d + kept] = 0;
			put16(meta + m, d);
			put16(meta + m + 2,
			    (kept + terminated) | (truncated ? 0x8000 : 0));
			d += kept + terminated;
		} else
			memcpy(meta + m, cmd->data, size);
		m += size;
		count++;
		if (cmd->type != SCALAR)
			flags |= 2;
		if (cmd->type != COUNT)
			precision = -1;
	}
	out[0] = flags;
	out[1] = count;
	memcpy(out + 2, meta, m);
	memcpy(out + 2 + m, data, d);
	*used = 2 + m + d;
	return (0);
}
struct output {
	char *p;
	size_t cap, n;
};
static int
append(struct output *o, const void *bytes, size_t n)
{
	if (o->n >= o->cap || n >= o->cap - o->n)
		return (ENOSPC);
	memcpy(o->p + o->n, bytes, n);
	o->n += n;
	o->p[o->n] = 0;
	return (0);
}
struct spec {
	size_t begin, end;
	char flags[8], length[3], conversion;
	int width, precision;
	bool width_arg, precision_arg, has_precision, secret;
};
static int
amount(const char *f, size_t n, size_t *p, int *value)
{
	unsigned x = 0;
	while (*p < n && f[*p] >= '0' && f[*p] <= '9') {
		x = x * 10 + f[(*p)++] - '0';
		if (x > MAX_FIELD)
			return (EINVAL);
	}
	*value = x;
	return (0);
}
static int
specifier(const char *f, size_t n, size_t *position, struct spec *s)
{
	size_t p = *position, start, flags = 0;
	int error;

	memset(s, 0, sizeof(*s));
	s->begin = p++;
	if (p < n && f[p] == '{') {
		start = ++p;
		while (p < n && f[p] != '}')
			p++;
		if (p == n || p - start > 128)
			return (EINVAL);
		s->secret = (p - start == 7 &&
				memcmp(f + start, "private", 7) == 0) ||
		    (p - start == 9 && memcmp(f + start, "sensitive", 9) == 0);
		p++;
	}
	while (p < n && strchr("-+ #0'", f[p]) != NULL) {
		if (flags == sizeof(s->flags) - 1)
			return (EINVAL);
		s->flags[flags++] = f[p++];
	}
	if (p < n && f[p] == '*') {
		s->width_arg = true;
		p++;
	} else if ((error = amount(f, n, &p, &s->width)) != 0)
		return (error);
	if (p < n && f[p] == '.') {
		s->has_precision = true;
		p++;
		if (p < n && f[p] == '*') {
			s->precision_arg = true;
			p++;
		} else if ((error = amount(f, n, &p, &s->precision)) != 0)
			return (error);
	}
	if (p < n && strchr("hljztLq", f[p]) != NULL) {
		s->length[0] = f[p++];
		if (p < n && (s->length[0] == 'h' || s->length[0] == 'l') &&
		    f[p] == s->length[0])
			s->length[1] = f[p++];
	}
	if (p == n || strchr("diouxXpcfFeEgGaAs", f[p]) == NULL)
		return (EINVAL);
	s->conversion = f[p++];
	s->end = p;
	*position = p;
	return (0);
}
static uint64_t
integer(const struct command *cmd)
{
	uint64_t value = 0;
	memcpy(&value, cmd->data, cmd->size);
	return (value);
}
static int
argument_int(const struct command *items, unsigned count, unsigned *index,
    unsigned kind, int *value)
{
	const struct command *cmd;
	if (*index == count)
		return (ENOENT);
	cmd = &items[(*index)++];
	if (cmd->type != kind || cmd->size != 4)
		return (EINVAL);
	if (cmd->flags & PRIVATE) {
		if (kind != COUNT)
			return (EINVAL);
		*value = 0;
		return (0);
	}
	memcpy(value, cmd->data, 4);
	return (0);
}
static int
number(struct output *out, const struct spec *s, const struct command *cmd)
{
	char fmt[64], bytes[8192];
	size_t off = 0;
	int result;
	uint64_t u;
	int64_t value;
	unsigned bits;
	double real;
	long double extended;
	locale_t locale;

	fmt[off++] = '%';
	memcpy(fmt + off, s->flags, strlen(s->flags));
	off += strlen(s->flags);
	if (s->width != 0)
		off += snprintf(fmt + off, sizeof(fmt) - off, "%d", s->width);
	if (s->has_precision)
		off += snprintf(fmt + off, sizeof(fmt) - off, ".%d",
		    s->precision);
	if (strchr("diouxX", s->conversion) != NULL)
		fmt[off++] = 'j';
	else if (s->length[0] == 'L' &&
	    strchr("fFeEgGaA", s->conversion) != NULL)
		fmt[off++] = 'L';
	fmt[off++] = s->conversion;
	fmt[off] = 0;
	locale = newlocale(LC_ALL_MASK, "C", NULL);
	if (locale == NULL)
		return (ENOMEM);
	if (strchr("fFeEgGaA", s->conversion) != NULL) {
		if (s->length[0] == 'L' && cmd->size == sizeof(extended)) {
			memcpy(&extended, cmd->data, sizeof(extended));
			result = snprintf_l(bytes, sizeof(bytes), locale, fmt,
			    extended);
		} else if (s->length[0] != 'L' && cmd->size == sizeof(real)) {
			memcpy(&real, cmd->data, sizeof(real));
			result = snprintf_l(bytes, sizeof(bytes), locale, fmt,
			    real);
		} else {
			freelocale(locale);
			return (EINVAL);
		}
	} else {
		if (cmd->size > 8) {
			freelocale(locale);
			return (EINVAL);
		}
		u = integer(cmd);
		bits = cmd->size * 8;
		if (strcmp(s->length, "hh") == 0) {
			bits = 8;
			u &= UINT8_MAX;
		} else if (strcmp(s->length, "h") == 0) {
			bits = 16;
			u &= UINT16_MAX;
		}
		value = (int64_t)u;
		if (bits < 64 && (u & (UINT64_C(1) << (bits - 1))))
			value = (int64_t)(u | (~UINT64_C(0) << bits));
		if (s->conversion == 'd' || s->conversion == 'i')
			result = snprintf_l(bytes, sizeof(bytes), locale, fmt,
			    (intmax_t)value);
		else if (s->conversion == 'p')
			result = snprintf_l(bytes, sizeof(bytes), locale, fmt,
			    (void *)(uintptr_t)u);
		else if (s->conversion == 'c')
			result = snprintf_l(bytes, sizeof(bytes), locale, fmt,
			    (int)(unsigned char)u);
		else
			result = snprintf_l(bytes, sizeof(bytes), locale, fmt,
			    (uintmax_t)u);
	}
	freelocale(locale);
	if (result < 0 || (size_t)result >= sizeof(bytes))
		return (EOVERFLOW);
	return (append(out, bytes, result));
}
int
__oslog_codec_render(const char *format, size_t size, const unsigned char *flat,
    size_t n, char *destination, size_t cap, size_t *used)
{
	struct command items[MAX_ITEMS];
	struct output out = { destination, cap, 0 };
	struct spec s;
	size_t end, i, p = 0, start, off, len;
	unsigned index = 0;
	int error, value, count_value;
	bool terminated;
	const struct command *cmd;
	char mismatch[256];

	if (used == NULL)
		return (EINVAL);
	*used = 0;
	if (format == NULL || destination == NULL || cap == 0 || size > 65536 ||
	    memchr(format, 0, size) != NULL)
		return (EINVAL);
	if ((error = commands(flat, n, items, &end, true)) != 0)
		return (error);
	for (i = 0; i < flat[1]; i++) {
		cmd = &items[i];
		if (cmd->flags & PRIVATE) {
			if (cmd->size != 4 ||
			    memcmp(cmd->data, "\0\0\0\0", 4) != 0)
				return (EINVAL);
		} else if (cmd->type == STRING || cmd->type == WIDE) {
			off = get16(cmd->data);
			len = get16(cmd->data + 2) & 0x7fff;
			terminated = true;
			if (i > 0 && items[i - 1].type == COUNT &&
			    !(items[i - 1].flags & PRIVATE)) {
				memcpy(&count_value, items[i - 1].data, 4);
				if (count_value >= 0 && !(get16(cmd->data + 2) & 0x8000))
					terminated = false;
			}
			if (off > n - end || len > n - end - off ||
			    (terminated && (len == 0 || flat[end + off + len - 1] != 0)) ||
			    memchr(flat + end + off, 0, len - terminated) != NULL)
				return (EINVAL);
		}
	}
	destination[0] = 0;
	while (p < size) {
		start = p;
		while (p < size && format[p] != '%')
			p++;
		if ((error = append(&out, format + start, p - start)) != 0)
			return (error);
		if (p == size)
			break;
		if (p + 1 < size && format[p + 1] == '%') {
			p += 2;
			if ((error = append(&out, "%", 1)) != 0)
				return (error);
			continue;
		}
		if ((error = specifier(format, size, &p, &s)) != 0)
			return (error);
		if (s.width_arg) {
			error = argument_int(items, flat[1], &index, SCALAR,
			    &value);
			if (error != 0 && error != ENOENT)
				return (error);
			if (error == ENOENT)
				goto missing;
			if (value < -MAX_FIELD || value > MAX_FIELD)
				return (EINVAL);
			s.width = value;
		}
		if (s.conversion == 's' && s.has_precision) {
			error = argument_int(items, flat[1], &index, COUNT,
			    &value);
			if (error != 0 && error != ENOENT)
				return (error);
			if (error == ENOENT)
				goto missing;
		} else if (s.precision_arg) {
			error = argument_int(items, flat[1], &index, SCALAR,
			    &value);
			if (error != 0 && error != ENOENT)
				return (error);
			if (error == ENOENT)
				goto missing;
			if (value > MAX_FIELD)
				return (EINVAL);
			s.precision = value;
			if (value < 0)
				s.has_precision = false;
		}
		if (index == flat[1]) {
		missing:
			if ((error = append(&out, "<decode: missing data>",
				 22)) != 0)
				return (error);
			continue;
		}
		cmd = &items[index++];
		if ((s.conversion == 's' && cmd->type != STRING) ||
		    (s.conversion != 's' && cmd->type != SCALAR))
			return (EINVAL);
		if ((cmd->flags & PRIVATE) || s.secret) {
			if ((error = append(&out, "<private>", 9)) != 0)
				return (error);
		} else if (s.conversion == 's') {
			off = get16(cmd->data);
			len = get16(cmd->data + 2) & 0x7fff;
			terminated = !s.has_precision || value < 0 ||
			    (get16(cmd->data + 2) & 0x8000) != 0;
			if (s.length[0] != 0) {
				value = snprintf(mismatch, sizeof(mismatch),
				    "<decode: mismatch for [%.*s] got [STRING%s sz:%zu]>",
				    (int)(s.end - s.begin), format + s.begin,
				    (cmd->flags & PUBLIC) ? " public" : "",
				    len);
				if (value < 0 ||
				    (size_t)value >= sizeof(mismatch))
					return (EINVAL);
				if ((error = append(&out, mismatch, value)) !=
				    0)
					return (error);
			} else {
				if ((error = append(&out, flat + end + off,
					 len - terminated)) != 0)
					return (error);
				if (get16(cmd->data + 2) & 0x8000)
					if ((error = append(&out,
						 "<\xe2\x80\xa6>", 5)) != 0)
						return (error);
			}
		} else if ((error = number(&out, &s, cmd)) != 0)
			return (error);
	}
	if (index != flat[1])
		return (EINVAL);
	*used = out.n;
	return (0);
}
