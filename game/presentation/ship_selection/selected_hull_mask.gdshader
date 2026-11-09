shader_type spatial;
render_mode unshaded, shadows_disabled, depth_draw_never;
// Match the selection ring's stencil reference. Keep the hull's normal depth test.
stencil_mode write, compare_always, 42;

void fragment() {
	ALPHA = 0.0;
}
