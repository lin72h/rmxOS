/* Host ABI adapter. The runner inserts the unmodified production parameter
 * handler and cli_main below. Configuration uses the real liblogstore parser;
 * retention records its input instead of opening the host's system store. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>
#include <asl.h>
#include <asl_private.h>
#include <asl_core.h>
#include <asl_store.h>
#include <asl_common.h>

/* RMX_PRODUCTION_DEFINES */
/* RMX_PRODUCTION_GLOBALS */

static const char *config_path;
static char observed_path[1024];
static uint32_t observed_ttl, observed_rules, observed_calls;
static size_t observed_size;

static asl_out_module_t *
host_config(void)
{
	asl_out_module_t *mod;
	asl_out_rule_t *r;
	FILE *f;

	if (config_path == NULL) return NULL;
	f = fopen(config_path, "r");
	if (f == NULL) abort();
	mod = asl_out_module_init_from_file(ASL_MODULE_NAME, f);
	fclose(f);
	if (mod == NULL) abort();
	for (r = mod->ruleset; r != NULL; r = r->next)
		if (r->action == ACTION_OUT_DEST) observed_rules++;
	return mod;
}

void set_debug(int flag, const char *level) { (void)level; debug |= flag; }
void debug_log(int level, const char *format, ...) { (void)level; (void)format; }
static int
process_asl_data_store(asl_out_dst_data_t *dst)
{
	if (!dryrun) abort();
	observed_calls++;
	strlcpy(observed_path, dst->path, sizeof(observed_path));
	observed_ttl = dst->ttl[LEVEL_ALL];
	observed_size = dst->all_max;
	return 0;
}
static void checkpoint(const char *name) { (void)name; abort(); }
static void process_module(asl_out_module_t *mod) { (void)mod; abort(); }
static uint32_t send_summary_checked(asl_msg_t *message) { (void)message; abort(); }

/* Only bypass the privilege check and project configuration discovery. */
#define geteuid() 0
#define asl_out_module_init host_config
/* RMX_PRODUCTION_PARAM */
/* RMX_PRODUCTION_CLI */

int
rmx_default_run(const char *path, int argc, char **argv)
{
	config_path = path;
	observed_path[0] = '\0';
	observed_ttl = observed_rules = observed_calls = 0;
	observed_size = 0;
	dryrun = debug = 0;
	return cli_main(argc, argv);
}
const char *rmx_default_path(void) { return observed_path; }
uint32_t rmx_default_ttl(void) { return observed_ttl; }
uint32_t rmx_default_rules(void) { return observed_rules; }
uint32_t rmx_default_calls(void) { return observed_calls; }
size_t rmx_default_size(void) { return observed_size; }
