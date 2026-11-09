shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec2 viewport_pixels;
uniform vec2 center;
uniform float floor_aspect;
uniform vec4 ring_color : source_color;
uniform float ring_radius;
uniform float stroke;
uniform float arc_radius;
uniform vec2 arc_direction;
uniform float arc_cosine;

bool in_stroke(float distance_to_center, float radius) {
	return distance_to_center <= radius && distance_to_center >= radius - stroke;
}

void fragment() {
	vec2 offset = (SCREEN_UV * viewport_pixels - center) / vec2(1.0, floor_aspect);
	float distance_to_center = length(offset);
	bool in_ring = in_stroke(distance_to_center, ring_radius);
	bool in_arc = arc_radius > 0.0 && in_stroke(distance_to_center, arc_radius)
		&& dot(offset, arc_direction) >= distance_to_center * arc_cosine;
	if (!in_ring && !in_arc) {
		discard;
	}
	ALBEDO = ring_color.rgb;
}
