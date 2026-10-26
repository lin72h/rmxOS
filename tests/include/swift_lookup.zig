// SPDX-License-Identifier: BSD-2-Clause
const c = @cImport({
    @cInclude("stdio.h");
});
extern fn op170_swift_value() c_int;
pub export fn main() c_int {
    const actual = op170_swift_value();
    _ = c.printf("op170_swift_runtime observed=%d expected=170\n", actual);
    return if (actual == 170) 0 else 1;
}
