/* Legacy parser moved unchanged from daemon.c; RFC 5424 has bounded input. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <limits.h>
#include "daemon.h"

/* RFC 5424 section 6: retain wire metadata and decoded structured data as keys. */
static int
asl_rfc5424_candidate(const char *in, size_t len)
{
	size_t i = 1;
	if (len < 5 || in[0] != '<') return 0;
	while (i < len && in[i] >= '0' && in[i] <= '9') i++;
	return i + 2 < len && in[i] == '>' && in[i + 1] == '1' && in[i + 2] == ' ';
}

static int
rfc_set(asl_msg_t *m, const char *key, const char *value, size_t length)
{
	char *copy = strndup(value, length);
	if (copy == NULL) return -1;
	int status = asl_msg_set_key_val(m, key, copy);
	free(copy);
	return status;
}

static int
rfc_name(char ch)
{
	return ch >= 33 && ch <= 126 && ch != '=' && ch != ']' && ch != '"';
}

static int
rfc_time(asl_msg_t *m, const char *text)
{
	if (!strcmp(text, "-")) return 0;
	struct tm tm = {0};
	char *p = strptime(text, "%Y-%m-%dT%H:%M:%S", &tm);
	if (p == NULL || tm.tm_sec > 59) return -1;
	struct tm original = tm;
	time_t seconds = timegm(&tm);
	if (tm.tm_year != original.tm_year || tm.tm_mon != original.tm_mon ||
	    tm.tm_mday != original.tm_mday || tm.tm_hour != original.tm_hour ||
	    tm.tm_min != original.tm_min || tm.tm_sec != original.tm_sec) return -1;
	unsigned nano = 0, digits = 0;
	if (*p == '.') {
		p++;
		while (*p >= '0' && *p <= '9' && digits < 6) {
			nano = nano * 10 + (*p++ - '0');
			digits++;
		}
		if (digits == 0 || (*p >= '0' && *p <= '9')) return -1;
	}
	for (unsigned i = digits; i < 9; i++) nano *= 10;
	if (*p == 'Z' && p[1] == '\0') {
		/* UTC */
	} else if ((*p == '+' || *p == '-') && strlen(p) == 6 &&
	    p[1] >= '0' && p[1] <= '9' && p[2] >= '0' && p[2] <= '9' &&
	    p[3] == ':' && p[4] >= '0' && p[4] <= '9' && p[5] >= '0' && p[5] <= '9') {
		int hours = (p[1] - '0') * 10 + p[2] - '0';
		int minutes = (p[4] - '0') * 10 + p[5] - '0';
		if (hours > 23 || minutes > 59) return -1;
		seconds += (*p == '+' ? -1 : 1) * (hours * 3600 + minutes * 60);
	} else return -1;
	char value[40];
	snprintf(value, sizeof(value), "%lld", (long long)seconds);
	if (asl_msg_set_key_val(m, ASL_KEY_TIME, value) != 0) return -1;
	snprintf(value, sizeof(value), "%u", nano);
	return asl_msg_set_key_val(m, ASL_KEY_TIME_NSEC, value);
}

static asl_msg_t *
asl_rfc5424_parse(const char *in, size_t len)
{
	const char *p = in + 1, *end = in + len, *start, *sd;
	unsigned priority = 0, count = 0;
	asl_msg_t *m = asl_msg_new(ASL_TYPE_MSG);
	if (m == NULL) return NULL;
	if (memchr(in, '\0', len) != NULL) goto invalid;
	while (p < end && *p >= '0' && *p <= '9' && count < 3) {
		priority = priority * 10 + (*p++ - '0');
		count++;
	}
	if (count == 0 || priority > 191 || end - p < 3 || memcmp(p, ">1 ", 3)) goto invalid;
	p += 3;
	const char *keys[] = { "RFC5424.Timestamp", ASL_KEY_HOST, ASL_KEY_SENDER, "RFC5424.ProcID", "RFC5424.MsgID" };
	size_t limits[] = { 32, 255, 48, 128, 32 };
	for (unsigned field = 0; field < 5; field++) {
		start = p;
		while (p < end && *p >= 33 && *p <= 126) p++;
		size_t n = (size_t)(p - start);
		if (n == 0 || n > limits[field] || p == end || *p != ' ') goto invalid;
		if (rfc_set(m, keys[field], start, n) != 0) goto invalid;
		p++;
	}
	if (rfc_time(m, asl_msg_get_val_for_key(m, "RFC5424.Timestamp")) != 0) goto invalid;
	const char *proc = asl_msg_get_val_for_key(m, "RFC5424.ProcID");
	int numeric = *proc != '\0';
	unsigned long pid_value = 0;
	for (const char *q = proc; *q; q++) {
		if (*q < '0' || *q > '9' || pid_value > (INT_MAX - (unsigned)(*q - '0')) / 10) {
			numeric = 0;
			break;
		}
		pid_value = pid_value * 10 + (*q - '0');
	}
	if (asl_msg_set_key_val(m, ASL_KEY_PID, numeric ? proc : "-1") != 0) goto invalid;
	char value[12];
	snprintf(value, sizeof(value), "%u", priority & 7);
	if (asl_msg_set_key_val(m, ASL_KEY_LEVEL, value) != 0) goto invalid;
	const char *facility = asl_syslog_faciliy_num_to_name(priority & LOG_FACMASK);
	if (asl_msg_set_key_val(m, ASL_KEY_FACILITY, facility ? facility : "user") != 0) goto invalid;
	if (asl_msg_set_key_val(m, ASL_KEY_UID, "-2") != 0 ||
	    asl_msg_set_key_val(m, ASL_KEY_GID, "-2") != 0) goto invalid;
	sd = p;
	if (p < end && *p == '-') p++;
	else {
		if (p == end || *p != '[') goto invalid;
		while (p < end && *p == '[') {
			start = ++p;
			while (p < end && rfc_name(*p) && *p != ' ') p++;
			size_t idlen = (size_t)(p - start);
			if (idlen == 0 || idlen > 32) goto invalid;
			char id[33], key[128];
			memcpy(id, start, idlen); id[idlen] = '\0';
			snprintf(key, sizeof(key), "RFC5424.SD.%zu:%s", idlen, id);
			if (asl_msg_set_key_val(m, key, "") != 0) goto invalid;
			while (p < end && *p == ' ') {
				start = ++p;
				while (p < end && rfc_name(*p) && *p != ' ') p++;
				size_t namelen = (size_t)(p - start);
				if (namelen == 0 || namelen > 32 || end - p < 2 || p[0] != '=' || p[1] != '"') goto invalid;
				char name[33]; memcpy(name, start, namelen); name[namelen] = '\0';
				p += 2;
				char *decoded = malloc((size_t)(end - p) + 1);
				if (decoded == NULL) goto invalid;
				size_t used = 0;
				while (p < end && *p != '"') {
					if (*p == '\\' && p + 1 < end && (p[1] == '\\' || p[1] == '"' || p[1] == ']')) p++;
					else if (*p == ']') { free(decoded); goto invalid; }
					decoded[used++] = *p++;
				}
				if (p == end) { free(decoded); goto invalid; }
				p++; decoded[used] = '\0';
				snprintf(key, sizeof(key), "RFC5424.SD.%zu:%s.%s", idlen, id, name);
				int status = asl_msg_set_key_val(m, key, decoded);
				free(decoded);
				if (status != 0) goto invalid;
			}
			if (p == end || *p++ != ']') goto invalid;
		}
	}
	if (rfc_set(m, "RFC5424.StructuredData", sd, (size_t)(p - sd)) != 0) goto invalid;
	if (p < end && *p++ != ' ') goto invalid;
	if (rfc_set(m, ASL_KEY_MSG, p, (size_t)(end - p)) != 0) goto invalid;
	return m;
invalid:
	asl_msg_release(m);
	return NULL;
}

static asl_msg_t *
asl_syslog_input_convert(const char *in, int len, char *rhost, uint32_t source)
{
	int pf, pri, index, n;
	char *p, *colon, *brace, *space, *tmp, *tval, *hval, *sval, *pval, *mval;
	char prival[8];
	const char *fval;
	asl_msg_t *msg;
	struct tm time;
	time_t tick;

	if (in == NULL) return NULL;
	if (len <= 0) return NULL;

	if (source != SOURCE_KERN && asl_rfc5424_candidate(in, (size_t)len))
		return asl_rfc5424_parse(in, (size_t)len);

	pri = LOG_DEBUG;
	if (source == SOURCE_KERN) pri = LOG_NOTICE;

	tval = NULL;
	hval = NULL;
	sval = NULL;
	pval = NULL;
	mval = NULL;
	fval = NULL;

	index = 0;
	p = (char *)in;

	/* skip leading whitespace */
	while ((index < len) && ((*p == ' ') || (*p == '\t')))
	{
		p++;
		index++;
	}

	if (index >= len) return NULL;

	/* parse "<NN>" priority (level and facility) */
	if (*p == '<')
	{
		p++;
		index++;

		n = sscanf(p, "%d", &pf);
		if (n == 1)
		{
			pri = pf & 0x7;
			if (pf > 0x7) fval = asl_syslog_faciliy_num_to_name(pf & LOG_FACMASK);
		}

		while ((index < len) && (*p != '>'))
		{
			p++;
			index++;
		}

		if (index < len)
		{
			p++;
			index++;
		}
	}

	snprintf(prival, sizeof(prival), "%d", pri);

	/* check if a timestamp is included */
	if (((len - index) > 15) && (p[9] == ':') && (p[12] == ':') && (p[15] == ' '))
	{
		tmp = malloc(16);
		if (tmp == NULL) return NULL;

		memcpy(tmp, p, 15);
		tmp[15] = '\0';

		tick = asl_core_parse_time(tmp, NULL);
		if (tick == (time_t)-1)
		{
			tval = tmp;
		}
		else
		{
			free(tmp);
			gmtime_r(&tick, &time);
			asprintf(&tval, "%d.%02d.%02d %02d:%02d:%02d UTC", time.tm_year + 1900, time.tm_mon + 1, time.tm_mday, time.tm_hour, time.tm_min, time.tm_sec);
		}

		p += 16;
		index += 16;
	}

	/* stop here for kernel messages */
	if (source == SOURCE_KERN)
	{
		msg = asl_msg_new(ASL_TYPE_MSG);
		if (msg == NULL) return NULL;

		asl_msg_set_key_val(msg, ASL_KEY_MSG, p);
		asl_msg_set_key_val(msg, ASL_KEY_LEVEL, prival);
		asl_msg_set_key_val(msg, ASL_KEY_PID, "0");

		return msg;
	}

	/* if message is from a network socket, hostname follows */
	if (source == SOURCE_UDP_SOCKET)
	{
		space = strchr(p, ' ');
		if (space != NULL)
		{
			n = space - p;
			hval = malloc(n + 1);
			if (hval == NULL) return NULL;

			memcpy(hval, p, n);
			hval[n] = '\0';

			p = space + 1;
			index += (n + 1);
		}
	}

	colon = strchr(p, ':');
	brace = strchr(p, '[');

	/* check for "sender:" or sender[pid]:"  */
	if (colon != NULL)
	{
		if ((brace != NULL) && (brace < colon))
		{
			n = brace - p;
			sval = malloc(n + 1);
			if (sval == NULL) return NULL;

			memcpy(sval, p, n);
			sval[n] = '\0';

			n = colon - (brace + 1) - 1;
			pval = malloc(n + 1);
			if (pval == NULL) return NULL;

			memcpy(pval, (brace + 1), n);
			pval[n] = '\0';
		}
		else
		{
			n = colon - p;
			sval = malloc(n + 1);
			if (sval == NULL) return NULL;

			memcpy(sval, p, n);
			sval[n] = '\0';
		}

		n = colon - p;
		p = colon + 1;
		index += (n + 1);
	}

	if (*p == ' ')
	{
		p++;
		index++;
	}

	n = len - index;
	if (n > 0)
	{
		mval = malloc(n + 1);
		if (mval == NULL) return NULL;

		memcpy(mval, p, n);
		mval[n] = '\0';
	}

	if (fval == NULL) fval = asl_syslog_faciliy_num_to_name(LOG_USER);

	msg = asl_msg_new(ASL_TYPE_MSG);
	if (msg == NULL) return NULL;

	if (tval != NULL)
	{
		asl_msg_set_key_val(msg, ASL_KEY_TIME, tval);
		free(tval);
	}

	if (fval != NULL) asl_msg_set_key_val(msg, "Facility", fval);
	else asl_msg_set_key_val(msg, "Facility", "user");

	if (sval != NULL)
	{
		asl_msg_set_key_val(msg, ASL_KEY_SENDER, sval);
		free(sval);
	}

	if (pval != NULL)
	{
		asl_msg_set_key_val(msg, ASL_KEY_PID, pval);
		free(pval);
	}
	else
	{
		asl_msg_set_key_val(msg, ASL_KEY_PID, "-1");
	}

	if (mval != NULL)
	{
		asl_msg_set_key_val(msg, ASL_KEY_MSG, mval);
		free(mval);
	}

	asl_msg_set_key_val(msg, ASL_KEY_LEVEL, prival);
	asl_msg_set_key_val(msg, ASL_KEY_UID, "-2");
	asl_msg_set_key_val(msg, ASL_KEY_GID, "-2");

	if (hval != NULL)
	{
		asl_msg_set_key_val(msg, ASL_KEY_HOST, hval);
		free(hval);
	}
	else if (rhost != NULL)
	{
		asl_msg_set_key_val(msg, ASL_KEY_HOST, rhost);
	}

	return msg;
}

asl_msg_t *
asl_input_parse(const char *in, int len, char *rhost, uint32_t source)
{
	asl_msg_t *msg;
	int status, x, legacy, off;

	asldebug("asl_input_parse: %s\n", (in == NULL) ? "NULL" : in);

	if (in == NULL) return NULL;

	legacy = 1;
	msg = NULL;

	/* calculate length if not provided */
	if (len == 0) len = strlen(in);

	/*
	 * Determine if the input is "old" syslog format or new ASL format.
	 * Old format lines should start with "<", but they can just be straight text.
	 * ASL input may start with a length (10 bytes) followed by a space and a '['.
	 * The length is optional, so ASL messages may also just start with '['.
	 */
	if ((in[0] != '<') && (len > 11))
	{
		status = sscanf(in, "%d ", &x);
		if ((status == 1) && (in[10] == ' ') && (in[11] == '[')) legacy = 0;
	}

	if (legacy == 1) return asl_syslog_input_convert(in, len, rhost, source);

	off = 11;
	if (in[0] == '[') off = 0;

	msg = asl_msg_from_string(in + off);
	if (msg == NULL) return NULL;

	if (rhost != NULL) asl_msg_set_key_val(msg, ASL_KEY_HOST, rhost);

	return msg;
}
