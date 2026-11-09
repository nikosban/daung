shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec2 viewport_pixels;
uniform vec2 center;
uniform float floor_aspect;
uniform vec4 ring_color : source_color;
uniform float ring_radius;
uniform float stroke;
uniform float world_stroke;
uniform mat4 clip_to_world;
uniform float arc_radius;
uniform vec2 arc_direction;
uniform float arc_cosine;

bool in_stroke(float distance_to_center, float radius) {
	return distance_to_center <= radius && distance_to_center >= radius - stroke;
}

// Intersect the viewport ray with world Y = 0 in homogeneous coordinates.
vec4 ground_edge(vec2 pixel) {
	vec2 ndc = pixel / viewport_pixels * vec2(2.0, -2.0) + vec2(-1.0, 1.0);
	vec4 ray_point = clip_to_world * vec4(ndc, 0.0, 1.0);
	vec4 depth_axis = clip_to_world[2];
	return ray_point - depth_axis * (ray_point.y / depth_axis.y);
}

void fragment() {
	vec2 offset = (SCREEN_UV * viewport_pixels - center) / vec2(1.0, floor_aspect);
	float distance_to_center = length(offset);
	bool in_ring = in_stroke(distance_to_center, ring_radius);
	if (world_stroke > 0.0 && distance_to_center <= ring_radius) {
		vec2 direction = distance_to_center > 0.0 ? offset / distance_to_center : vec2(1.0, 0.0);
		vec2 edge_pixel = center + direction * ring_radius * vec2(1.0, floor_aspect);
		vec4 edge = ground_edge(edge_pixel);
		vec3 world_point = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		in_ring = edge.w > 0.0 && distance(world_point.xz, edge.xz / edge.w) <= world_stroke;
	}
	bool in_arc = arc_radius > 0.0 && in_stroke(distance_to_center, arc_radius)
		&& dot(offset, arc_direction) >= distance_to_center * arc_cosine;
	if (!in_ring && !in_arc) {
		discard;
	}
	ALBEDO = ring_color.rgb;
}
