/* Compiler input only: actual Clang os_log buffer lowering. */
#include "codec_fixture.h"
void fixture_0(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z begin";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z begin");
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z begin");
}
void fixture_1(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy s_literal=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy s_literal=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy s_literal=[%s]", in->strings[0]);
}
void fixture_2(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy s_runtime=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy s_runtime=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy s_runtime=[%s]", in->strings[0]);
}
void fixture_3(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy d=[%d]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy d=[%d]", in->i32);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy d=[%d]", in->i32);
}
void fixture_4(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy u=[%u]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy u=[%u]", in->i32);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy u=[%u]", in->i32);
}
void fixture_5(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy x=[%x]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy x=[%x]", in->i32);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy x=[%x]", in->i32);
}
void fixture_6(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy p=[%p]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy p=[%p]", (void *)in->pointer);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy p=[%p]", (void *)in->pointer);
}
void fixture_7(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy f=[%f]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy f=[%f]", in->real);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy f=[%f]", in->real);
}
void fixture_8(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy c=[%c]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy c=[%c]", in->i32);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy c=[%c]", in->i32);
}
void fixture_9(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy public_literal=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy public_literal=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy public_literal=[%{public}s]", in->strings[0]);
}
void fixture_10(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy public_runtime=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy public_runtime=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy public_runtime=[%{public}s]", in->strings[0]);
}
void fixture_11(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy private_literal=[%{private}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy private_literal=[%{private}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy private_literal=[%{private}s]", in->strings[0]);
}
void fixture_12(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z privacy private_runtime=[%{private}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z privacy private_runtime=[%{private}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z privacy private_runtime=[%{private}s]", in->strings[0]);
}
void fixture_13(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields macro=default log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields macro=default log=%{public}s", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields macro=default log=%{public}s", in->strings[0]);
}
void fixture_14(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields macro=info log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields macro=info log=%{public}s", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields macro=info log=%{public}s", in->strings[0]);
}
void fixture_15(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields macro=error log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields macro=error log=%{public}s", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields macro=error log=%{public}s", in->strings[0]);
}
void fixture_16(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields macro=fault log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields macro=fault log=%{public}s", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields macro=fault log=%{public}s", in->strings[0]);
}
void fixture_17(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
}
void fixture_18(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
}
void fixture_19(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
}
void fixture_20(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
}
void fixture_21(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields macro=default log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields macro=default log=%{public}s", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields macro=default log=%{public}s", in->strings[0]);
}
void fixture_22(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields macro=info log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields macro=info log=%{public}s", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields macro=info log=%{public}s", in->strings[0]);
}
void fixture_23(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields macro=error log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields macro=error log=%{public}s", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields macro=error log=%{public}s", in->strings[0]);
}
void fixture_24(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields macro=fault log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields macro=fault log=%{public}s", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields macro=fault log=%{public}s", in->strings[0]);
}
void fixture_25(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
}
void fixture_26(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
}
void fixture_27(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
}
void fixture_28(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z fields with_type=%{public}s log=%{public}s", in->strings[0], in->strings[1]);
}
void fixture_29(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z long begin[%{public}s]end";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z long begin[%{public}s]end", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z long begin[%{public}s]end", in->strings[0]);
}
void fixture_30(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z end";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z end");
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z end");
}
void fixture_31(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z decoder before";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z decoder before");
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z decoder before");
}
void fixture_32(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z decoder value=%{rmxnope}d";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z decoder value=%{rmxnope}d", in->i32);
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z decoder value=%{rmxnope}d", in->i32);
}
void fixture_33(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop963-20261023T041823Z decoder after";
 out->size = __builtin_os_log_format_buffer_size("rmxop963-20261023T041823Z decoder after");
 __builtin_os_log_format(out->bytes, "rmxop963-20261023T041823Z decoder after");
}
void fixture_34(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z begin";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z begin");
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z begin");
}
void fixture_35(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A01 value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A01 value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A01 value=[%s]", in->strings[0]);
}
void fixture_37(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A03 value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A03 value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A03 value=[%s]", in->strings[0]);
}
void fixture_38(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A04a value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A04a value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A04a value=[%s]", in->strings[0]);
}
void fixture_39(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A04b value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A04b value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A04b value=[%s]", in->strings[0]);
}
void fixture_40(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A05a value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A05a value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A05a value=[%s]", in->strings[0]);
}
void fixture_41(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A05b value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A05b value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A05b value=[%s]", in->strings[0]);
}
void fixture_42(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A05c value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A05c value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A05c value=[%s]", in->strings[0]);
}
void fixture_43(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A05d value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A05d value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A05d value=[%s]", in->strings[0]);
}
void fixture_44(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A05e value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A05e value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A05e value=[%s]", in->strings[0]);
}
void fixture_45(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A06a value=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A06a value=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A06a value=[%s]", in->strings[0]);
}
void fixture_46(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A06b value=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A06b value=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A06b value=[%{public}s]", in->strings[0]);
}
void fixture_47(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A07a value=[%{private}d]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A07a value=[%{private}d]", in->i32);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A07a value=[%{private}d]", in->i32);
}
void fixture_48(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A07b value=[%{sensitive}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A07b value=[%{sensitive}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A07b value=[%{sensitive}s]", in->strings[0]);
}
void fixture_49(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A07c value=[%{public}ls]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A07c value=[%{public}ls]", (const wchar_t *)(uintptr_t)in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A07c value=[%{public}ls]", (const wchar_t *)(uintptr_t)in->strings[0]);
}
void fixture_50(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z A07d value=[%ls]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z A07d value=[%ls]", (const wchar_t *)(uintptr_t)in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z A07d value=[%ls]", (const wchar_t *)(uintptr_t)in->strings[0]);
}
void fixture_51(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B01a s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B01a s=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B01a s=[%{public}s]", in->strings[0]);
}
void fixture_52(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B01b s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B01b s=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B01b s=[%{public}s]", in->strings[0]);
}
void fixture_53(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B01c s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B01c s=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B01c s=[%{public}s]", in->strings[0]);
}
void fixture_54(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B02a n=[%d] s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B02a n=[%d] s=[%{public}s]", in->i32, in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B02a n=[%d] s=[%{public}s]", in->i32, in->strings[0]);
}
void fixture_55(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B02b n=[%ld] s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B02b n=[%ld] s=[%{public}s]", (long)in->i64, in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B02b n=[%ld] s=[%{public}s]", (long)in->i64, in->strings[0]);
}
void fixture_56(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B03 s1=[%{public}s] s2=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B03 s1=[%{public}s] s2=[%{public}s]", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B03 s1=[%{public}s] s2=[%{public}s]", in->strings[0], in->strings[1]);
}
void fixture_57(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B04 s1=[%{public}s] s2=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B04 s1=[%{public}s] s2=[%{public}s]", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B04 s1=[%{public}s] s2=[%{public}s]", in->strings[0], in->strings[1]);
}
void fixture_58(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B05 private=[%s] s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B05 private=[%s] s=[%{public}s]", in->strings[0], in->strings[1]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B05 private=[%s] s=[%{public}s]", in->strings[0], in->strings[1]);
}
void fixture_59(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B06 n=[%{private}ld] s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B06 n=[%{private}ld] s=[%{public}s]", (long)in->i64, in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B06 n=[%{private}ld] s=[%{public}s]", (long)in->i64, in->strings[0]);
}
void fixture_60(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B07a s=[%{public}.2000s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B07a s=[%{public}.2000s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B07a s=[%{public}.2000s]", in->strings[0]);
}
void fixture_61(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B07b s=[%{public}.*s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B07b s=[%{public}.*s]", in->precision, in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B07b s=[%{public}.*s]", in->precision, in->strings[0]);
}
void fixture_62(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B07c s=[%.2000s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B07c s=[%.2000s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B07c s=[%.2000s]", in->strings[0]);
}
void fixture_63(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B07d s=[%.*s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B07d s=[%.*s]", in->precision, in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B07d s=[%.*s]", in->precision, in->strings[0]);
}
void fixture_64(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B08a s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B08a s=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B08a s=[%{public}s]", in->strings[0]);
}
void fixture_65(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B08b s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B08b s=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B08b s=[%{public}s]", in->strings[0]);
}
void fixture_66(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B08c s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B08c s=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B08c s=[%{public}s]", in->strings[0]);
}
void fixture_67(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B08d s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B08d s=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B08d s=[%{public}s]", in->strings[0]);
}
void fixture_68(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B09a literal=[AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA] short=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B09a literal=[AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA] short=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B09a literal=[AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA] short=[%{public}s]", in->strings[0]);
}
void fixture_69(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B09b s=[%s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B09b s=[%s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B09b s=[%s]", in->strings[0]);
}
void fixture_70(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B09c s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B09c s=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B09c s=[%{public}s]", in->strings[0]);
}
void fixture_71(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B10 s=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B10 s=[%{public}s]", in->strings[0]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B10 s=[%{public}s]", in->strings[0]);
}
void fixture_72(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z B11 1=[%{public}s] 2=[%{public}s] 3=[%{public}s] 4=[%{public}s] 5=[%{public}s] 6=[%{public}s] 7=[%{public}s] 8=[%{public}s] 9=[%{public}s] 10=[%{public}s] 11=[%{public}s] 12=[%{public}s] 13=[%{public}s] 14=[%{public}s] 15=[%{public}s] 16=[%{public}s] 17=[%{public}s] 18=[%{public}s] 19=[%{public}s] 20=[%{public}s] 21=[%{public}s] 22=[%{public}s] 23=[%{public}s] 24=[%{public}s] 25=[%{public}s] 26=[%{public}s] 27=[%{public}s] 28=[%{public}s] 29=[%{public}s] 30=[%{public}s] 31=[%{public}s] 32=[%{public}s] 33=[%{public}s]";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z B11 1=[%{public}s] 2=[%{public}s] 3=[%{public}s] 4=[%{public}s] 5=[%{public}s] 6=[%{public}s] 7=[%{public}s] 8=[%{public}s] 9=[%{public}s] 10=[%{public}s] 11=[%{public}s] 12=[%{public}s] 13=[%{public}s] 14=[%{public}s] 15=[%{public}s] 16=[%{public}s] 17=[%{public}s] 18=[%{public}s] 19=[%{public}s] 20=[%{public}s] 21=[%{public}s] 22=[%{public}s] 23=[%{public}s] 24=[%{public}s] 25=[%{public}s] 26=[%{public}s] 27=[%{public}s] 28=[%{public}s] 29=[%{public}s] 30=[%{public}s] 31=[%{public}s] 32=[%{public}s] 33=[%{public}s]", in->strings[0], in->strings[1], in->strings[2], in->strings[3], in->strings[4], in->strings[5], in->strings[6], in->strings[7], in->strings[8], in->strings[9], in->strings[10], in->strings[11], in->strings[12], in->strings[13], in->strings[14], in->strings[15], in->strings[16], in->strings[17], in->strings[18], in->strings[19], in->strings[20], in->strings[21], in->strings[22], in->strings[23], in->strings[24], in->strings[25], in->strings[26], in->strings[27], in->strings[28], in->strings[29], in->strings[30], in->strings[31], in->strings[32]);
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z B11 1=[%{public}s] 2=[%{public}s] 3=[%{public}s] 4=[%{public}s] 5=[%{public}s] 6=[%{public}s] 7=[%{public}s] 8=[%{public}s] 9=[%{public}s] 10=[%{public}s] 11=[%{public}s] 12=[%{public}s] 13=[%{public}s] 14=[%{public}s] 15=[%{public}s] 16=[%{public}s] 17=[%{public}s] 18=[%{public}s] 19=[%{public}s] 20=[%{public}s] 21=[%{public}s] 22=[%{public}s] 23=[%{public}s] 24=[%{public}s] 25=[%{public}s] 26=[%{public}s] 27=[%{public}s] 28=[%{public}s] 29=[%{public}s] 30=[%{public}s] 31=[%{public}s] 32=[%{public}s] 33=[%{public}s]", in->strings[0], in->strings[1], in->strings[2], in->strings[3], in->strings[4], in->strings[5], in->strings[6], in->strings[7], in->strings[8], in->strings[9], in->strings[10], in->strings[11], in->strings[12], in->strings[13], in->strings[14], in->strings[15], in->strings[16], in->strings[17], in->strings[18], in->strings[19], in->strings[20], in->strings[21], in->strings[22], in->strings[23], in->strings[24], in->strings[25], in->strings[26], in->strings[27], in->strings[28], in->strings[29], in->strings[30], in->strings[31], in->strings[32]);
}
void fixture_73(struct codec_input *in, struct codec_sample *out) {
 (void)in;
 out->format = "rmxop970-20261023T052953Z end";
 out->size = __builtin_os_log_format_buffer_size("rmxop970-20261023T052953Z end");
 __builtin_os_log_format(out->bytes, "rmxop970-20261023T052953Z end");
}
static const char const_array[] = "static-const-array";
static char writable_array[] = "static-writable-array";
const char *fixture_literal(int n) { switch(n) { case 0: return "literal-text"; case 1: return "main-literal"; case 2: return const_array; case 3: return writable_array; case 4: return "prefix-middle-literal" + 7; case 5: return "sensitive-literal"; case 6: return "abc"; case 7: return "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; default: return 0; } }
const char *main(void) __asm__("fixture_func_literal");
const char *main(void) { return __func__; }
const char *fixture_wide_literal(void) { return (const char *)L"wide-literal-é"; }
extern const char *const sys_errlist[];
const char *fixture_error_literal(void) { return sys_errlist[2]; }
void fixture_edges(struct codec_input *in, struct codec_sample *out) {
#define EDGE_FMT "[%+08d][%#x][%hhd][%.2f][%.*s][%{private}.3s][%%][%p]"
out->format = EDGE_FMT; out->size = __builtin_os_log_format_buffer_size(EDGE_FMT, 42, 42u, 255, 3.25, 3, in->strings[0], in->strings[0], (void *)0);
__builtin_os_log_format(out->bytes, EDGE_FMT, 42, 42u, 255, 3.25, 3, in->strings[0], in->strings[0], (void *)0);
}
