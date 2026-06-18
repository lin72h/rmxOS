#include "plist_to_launch_data.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <bsdxml.h>

enum plist_node_kind {
	PLIST_NODE_ARRAY,
	PLIST_NODE_DICT,
};

struct plist_node {
	enum plist_node_kind kind;
	launch_data_t value;
	char *pending_key;
	size_t next_index;
};

struct plist_parser {
	const char *path;
	XML_Parser parser;
	launch_data_t root;
	struct plist_node *stack;
	size_t stack_len;
	size_t stack_cap;
	char *text;
	size_t text_len;
	size_t text_cap;
	bool failed;
	bool saw_plist;
	char error[256];
};

static void
set_error(struct plist_parser *p, const char *fmt, ...)
{
	va_list ap;

	if (p->failed)
		return;
	p->failed = true;
	va_start(ap, fmt);
	vsnprintf(p->error, sizeof(p->error), fmt, ap);
	va_end(ap);
}

static char *
xstrndup(const char *s, size_t len)
{
	char *out;

	out = malloc(len + 1);
	if (out == NULL)
		return (NULL);
	memcpy(out, s, len);
	out[len] = '\0';
	return (out);
}

static char *
trimmed_text(struct plist_parser *p)
{
	size_t start, end;

	start = 0;
	end = p->text_len;
	while (start < end && isspace((unsigned char)p->text[start]))
		start++;
	while (end > start && isspace((unsigned char)p->text[end - 1]))
		end--;
	return (xstrndup(p->text + start, end - start));
}

static bool
append_text(struct plist_parser *p, const char *s, int len)
{
	char *new_text;
	size_t need;

	if (len <= 0)
		return (true);
	need = p->text_len + (size_t)len + 1;
	if (need > p->text_cap) {
		size_t new_cap = p->text_cap == 0 ? 128 : p->text_cap;
		while (new_cap < need)
			new_cap *= 2;
		new_text = realloc(p->text, new_cap);
		if (new_text == NULL)
			return (false);
		p->text = new_text;
		p->text_cap = new_cap;
	}
	memcpy(p->text + p->text_len, s, (size_t)len);
	p->text_len += (size_t)len;
	p->text[p->text_len] = '\0';
	return (true);
}

static void
clear_text(struct plist_parser *p)
{
	p->text_len = 0;
	if (p->text != NULL)
		p->text[0] = '\0';
}

static struct plist_node *
top_node(struct plist_parser *p)
{
	if (p->stack_len == 0)
		return (NULL);
	return (&p->stack[p->stack_len - 1]);
}

static bool
push_node(struct plist_parser *p, enum plist_node_kind kind, launch_data_t value)
{
	struct plist_node *new_stack;
	struct plist_node *node;
	size_t new_cap;

	if (p->stack_len == p->stack_cap) {
		new_cap = p->stack_cap == 0 ? 8 : p->stack_cap * 2;
		new_stack = realloc(p->stack, new_cap * sizeof(*p->stack));
		if (new_stack == NULL)
			return (false);
		p->stack = new_stack;
		p->stack_cap = new_cap;
	}
	node = &p->stack[p->stack_len++];
	node->kind = kind;
	node->value = value;
	node->pending_key = NULL;
	node->next_index = 0;
	return (true);
}

static launch_data_t
pop_node(struct plist_parser *p)
{
	struct plist_node *node;
	launch_data_t value;

	if (p->stack_len == 0)
		return (NULL);
	node = &p->stack[p->stack_len - 1];
	value = node->value;
	if (node->pending_key != NULL) {
		set_error(p, "%s: dict key without value", p->path);
		free(node->pending_key);
		node->pending_key = NULL;
	}
	p->stack_len--;
	return (value);
}

static void
attach_value(struct plist_parser *p, launch_data_t value)
{
	struct plist_node *node;

	if (value == NULL) {
		set_error(p, "%s: failed to allocate launch_data value", p->path);
		return;
	}
	node = top_node(p);
	if (node == NULL) {
		if (p->root != NULL) {
			launch_data_free(value);
			set_error(p, "%s: multiple root plist values", p->path);
			return;
		}
		p->root = value;
		return;
	}
	if (node->kind == PLIST_NODE_ARRAY) {
		launch_data_array_set_index(node->value, value, node->next_index++);
		return;
	}
	if (node->pending_key == NULL) {
		launch_data_free(value);
		set_error(p, "%s: dict value without key", p->path);
		return;
	}
	if (launch_data_dict_lookup(node->value, node->pending_key) != NULL) {
		launch_data_free(value);
		set_error(p, "%s: duplicate dict key '%s'", p->path,
		    node->pending_key);
		free(node->pending_key);
		node->pending_key = NULL;
		return;
	}
	launch_data_dict_insert(node->value, value, node->pending_key);
	free(node->pending_key);
	node->pending_key = NULL;
}

static void
push_container(struct plist_parser *p, enum plist_node_kind kind)
{
	launch_data_t value;

	value = launch_data_alloc(kind == PLIST_NODE_DICT ?
	    LAUNCH_DATA_DICTIONARY : LAUNCH_DATA_ARRAY);
	if (value == NULL || !push_node(p, kind, value)) {
		if (value != NULL)
			launch_data_free(value);
		set_error(p, "%s: failed to allocate container", p->path);
	}
}

static void XMLCALL
start_element(void *ctx, const char *name, const char **atts)
{
	struct plist_parser *p = ctx;

	(void)atts;
	if (p->failed)
		return;
	clear_text(p);
	if (strcmp(name, "plist") == 0) {
		p->saw_plist = true;
		return;
	}
	if (strcmp(name, "dict") == 0) {
		push_container(p, PLIST_NODE_DICT);
		return;
	}
	if (strcmp(name, "array") == 0) {
		push_container(p, PLIST_NODE_ARRAY);
		return;
	}
	if (strcmp(name, "key") == 0 || strcmp(name, "string") == 0 ||
	    strcmp(name, "integer") == 0 || strcmp(name, "true") == 0 ||
	    strcmp(name, "false") == 0)
		return;
	set_error(p, "%s: unsupported plist node <%s>", p->path, name);
}

static long long
parse_integer(const char *s, bool *ok)
{
	char *end;
	long long value;

	errno = 0;
	value = strtoll(s, &end, 10);
	while (end != NULL && *end != '\0' && isspace((unsigned char)*end))
		end++;
	*ok = errno == 0 && end != NULL && *end == '\0';
	return (value);
}

static void XMLCALL
end_element(void *ctx, const char *name)
{
	struct plist_parser *p = ctx;
	struct plist_node *node;
	launch_data_t value;
	char *text;
	bool ok;
	long long integer_value;

	if (p->failed)
		return;
	if (strcmp(name, "plist") == 0) {
		clear_text(p);
		return;
	}
	if (strcmp(name, "dict") == 0 || strcmp(name, "array") == 0) {
		value = pop_node(p);
		if (!p->failed)
			attach_value(p, value);
		clear_text(p);
		return;
	}
	if (strcmp(name, "key") == 0) {
		node = top_node(p);
		text = trimmed_text(p);
		if (node == NULL || node->kind != PLIST_NODE_DICT) {
			free(text);
			set_error(p, "%s: <key> outside <dict>", p->path);
			return;
		}
		if (node->pending_key != NULL) {
			free(text);
			set_error(p, "%s: duplicate pending dict key", p->path);
			return;
		}
		if (text == NULL) {
			set_error(p, "%s: failed to allocate key text", p->path);
			return;
		}
		node->pending_key = text;
		clear_text(p);
		return;
	}
	if (strcmp(name, "string") == 0) {
		text = trimmed_text(p);
		if (text == NULL) {
			set_error(p, "%s: failed to allocate string text", p->path);
			return;
		}
		value = launch_data_new_string(text);
		free(text);
		attach_value(p, value);
		clear_text(p);
		return;
	}
	if (strcmp(name, "integer") == 0) {
		text = trimmed_text(p);
		if (text == NULL) {
			set_error(p, "%s: failed to allocate integer text", p->path);
			return;
		}
		integer_value = parse_integer(text, &ok);
		free(text);
		if (!ok) {
			set_error(p, "%s: invalid integer value", p->path);
			return;
		}
		attach_value(p, launch_data_new_integer(integer_value));
		clear_text(p);
		return;
	}
	if (strcmp(name, "true") == 0) {
		attach_value(p, launch_data_new_bool(true));
		clear_text(p);
		return;
	}
	if (strcmp(name, "false") == 0) {
		attach_value(p, launch_data_new_bool(false));
		clear_text(p);
		return;
	}
}

static void XMLCALL
character_data(void *ctx, const char *s, int len)
{
	struct plist_parser *p = ctx;

	if (!p->failed && !append_text(p, s, len))
		set_error(p, "%s: failed to allocate text buffer", p->path);
}

static void
free_parser(struct plist_parser *p)
{
	size_t i;

	if (p->parser != NULL)
		XML_ParserFree(p->parser);
	for (i = 0; i < p->stack_len; i++)
		free(p->stack[i].pending_key);
	free(p->stack);
	free(p->text);
}

launch_data_t
plist_to_launch_data_file(const char *path, char *error, size_t error_size)
{
	struct plist_parser p;
	FILE *f;
	char buf[8192];
	size_t nread;
	int done;

	memset(&p, 0, sizeof(p));
	p.path = path;
	p.parser = XML_ParserCreate(NULL);
	if (p.parser == NULL) {
		if (error_size > 0)
			snprintf(error, error_size, "%s: failed to create XML parser", path);
		return (NULL);
	}
	XML_SetUserData(p.parser, &p);
	XML_SetElementHandler(p.parser, start_element, end_element);
	XML_SetCharacterDataHandler(p.parser, character_data);

	f = fopen(path, "rb");
	if (f == NULL) {
		snprintf(p.error, sizeof(p.error), "%s: %s", path, strerror(errno));
		p.failed = true;
		goto out;
	}
	do {
		nread = fread(buf, 1, sizeof(buf), f);
		done = feof(f);
		if (XML_Parse(p.parser, buf, (int)nread, done) == XML_STATUS_ERROR) {
			set_error(&p, "%s: XML parse error at line %lu: %s", path,
			    XML_GetCurrentLineNumber(p.parser),
			    XML_ErrorString(XML_GetErrorCode(p.parser)));
			break;
		}
	} while (!done && !p.failed);
	if (ferror(f))
		set_error(&p, "%s: read error", path);
	fclose(f);

out:
	if (!p.failed && !p.saw_plist)
		set_error(&p, "%s: missing <plist> root", path);
	if (!p.failed && p.stack_len != 0)
		set_error(&p, "%s: unclosed plist container", path);
	if (!p.failed && p.root == NULL)
		set_error(&p, "%s: plist did not produce a value", path);

	if (p.failed) {
		if (error_size > 0)
			snprintf(error, error_size, "%s", p.error);
		if (p.root != NULL)
			launch_data_free(p.root);
		p.root = NULL;
	}
	free_parser(&p);
	return (p.root);
}
