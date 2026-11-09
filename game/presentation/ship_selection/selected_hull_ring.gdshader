shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never, depth_test_disabled;
stencil_mode read, compare_equal, 42;

#define DRAW_OVER_SELECTED_HULL
#include "res://game/presentation/ground_feedback_shape.gdshaderinc"
