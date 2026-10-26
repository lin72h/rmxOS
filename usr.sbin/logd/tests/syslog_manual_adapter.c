/* Host-only ABI access to the production parser and rule matcher. */
#ifndef RMX_BSD_OUT_SOURCE
#define RMX_BSD_OUT_SOURCE "../bsd_out.c"
#endif
#include RMX_BSD_OUT_SOURCE

#include "syslog_input.c"
#include "telemetry.c"
int internal_log_message(const char *message) { (void)message; return 0; }

void *rmx_manual_report(const char *wire)
{
 asl_msg_t *m = asl_rfc5424_parse(wire, strlen(wire));
 if (m) logd_count_sender_drops(m);
 return m;
}

uint64_t rmx_manual_sender_dropped(void)
{
 return logd_counters.sender_dropped;
}

void *rmx_manual_native_report(const char *record)
{
 asl_msg_t *m = asl_msg_from_string(record);
 if (m) logd_count_sender_drops(m);
 return m;
}

unsigned rmx_manual_load(const char *path)
{
 struct config_rule *r;
 while ((r = TAILQ_FIRST(&bsd_out_rule)) != NULL) {
  TAILQ_REMOVE(&bsd_out_rule, r, entries);
  _free_rule(r);
 }
 TAILQ_INIT(&bsd_out_rule);
 logd_counters.config_rejected = 0;
 if (_parse_config_file(path)) return ~0U;
 unsigned count = 0;
 TAILQ_FOREACH(r, &bsd_out_rule, entries) count++;
 return logd_counters.config_rejected ? ~0U : count;
}

static struct config_rule *rmx_manual_rule(unsigned index)
{
 struct config_rule *r;
 TAILQ_FOREACH(r, &bsd_out_rule, entries) { if (!index--) return r; }
 return NULL;
}

const char *rmx_manual_destination(unsigned index)
{
 struct config_rule *r = rmx_manual_rule(index);
 return r ? r->dst : NULL;
}

int rmx_manual_match(unsigned index, const char *facility, const char *level,
    const char *sender)
{
 asl_msg_t *msg = asl_msg_new(ASL_TYPE_MSG);
 asl_msg_set_key_val(msg, ASL_KEY_FACILITY, facility);
 asl_msg_set_key_val(msg, ASL_KEY_LEVEL, level);
 asl_msg_set_key_val(msg, ASL_KEY_SENDER, sender);
 asl_msg_set_key_val(msg, ASL_KEY_MSG, "ftpd: message body is not the Sender");
 int match = _bsd_rule_match(msg, rmx_manual_rule(index));
 asl_msg_release(msg);
 return match;
}

char *rmx_manual_kernel_text(void)
{
 asl_msg_t *msg = asl_msg_new(ASL_TYPE_MSG);
 asl_msg_set_key_val(msg, ASL_KEY_SENDER, "kernel");
 asl_msg_set_key_val(msg, ASL_KEY_PID, "0");
 asl_msg_set_key_val(msg, ASL_KEY_MSG, "kernel format check");
 uint32_t length;
 char *text = asl_format_message(msg, ASL_MSG_FMT_BSD, ASL_TIME_FMT_LCL,
     ASL_ENCODE_SAFE, &length);
 asl_msg_release(msg);
 return text;
}
