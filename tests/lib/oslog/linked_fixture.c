#include "codec_fixture.h"
const char *fixture_linked_literal(void) { return "foo-literal"; }
void fixture_36(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A02 value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A02 value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A02 value=[%s]", in->strings[0]);
}
