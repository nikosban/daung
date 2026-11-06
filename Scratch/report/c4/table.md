
**turn90**

| metric | c3 | c4 |
|---|---|---|
| speed_at_activation | 15.00 | 15.00 |
| turn_radius | 54.55 | 16.87 |
| turn_min_speed | 3.48 | 1.27 |
| speed_lost | 8.18 | 9.06 |
| drift_past_destination_line | 75.22 | 74.72 |
| arrival_time | 22.67 | 34.52 |
| turn_exit_time | 9.13 | 8.70 |
| max_bow_to_travel | 105.57 | 64.56 |
| bow_to_travel_last_over_5deg | 22.63 | 34.48 |
| bow_to_path_last_over_5deg | 15.30 | 34.48 |
| final_miss | 0.04 | 0.31 |
| turn_sign_flips_last_10s | 2 | 0 |
| leg_max_bow_travel | 102.20 | 64.56 |
| leg_mean_bow_travel | 30.58 | 31.41 |
| leg_share_under_5deg | 0.08 | 0.05 |
| leg_settled_under_5deg | n/a | n/a |
| max_thrust_fraction | 1.00 | 1.00 |
| profile_unchanged | yes | yes |

**turn180**

| metric | c3 | c4 |
|---|---|---|
| speed_at_activation | 14.97 | 14.97 |
| turn_radius | 16.11 | 12.77 |
| speed_lost | 12.25 | 12.40 |
| forward_overshoot_past_order_point | 58.02 | 58.05 |
| arrival_time | 27.10 | 27.15 |
| turn_exit_time | 13.58 | 13.22 |
| max_bow_to_travel | 56.97 | 57.29 |
| bow_to_travel_last_over_5deg | 27.07 | 16.30 |
| bow_to_path_last_over_5deg | 20.05 | 27.12 |
| final_miss | 0.08 | 0.63 |
| turn_sign_flips_last_10s | 2 | 0 |
| leg_max_bow_travel | 14.59 | 11.42 |
| leg_mean_bow_travel | 8.52 | 2.67 |
| leg_share_under_5deg | 0.23 | 0.76 |
| leg_settled_under_5deg | n/a | 3.18 |
| max_thrust_fraction | 1.00 | 1.00 |
| profile_unchanged | yes | yes |

**arrive**

| metric | c3 | c4 |
|---|---|---|
| speed_at_activation | 15.00 | 15.00 |
| arrival_time | 9.87 | 9.87 |
| final_miss | 0.08 | 0.08 |
| max_thrust_fraction | 1.00 | 1.00 |
| profile_unchanged | yes | yes |

**brake**

| metric | c3 | c4 |
|---|---|---|
| speed_at_activation | 14.94 | 14.94 |
| stopping_distance | 33.47 | 33.47 |
| stopping_time | 5.32 | 5.32 |
| peak_sternward_thrust | 3.33 | 3.33 |
| max_speed_drop_per_tick | 0.06 | 0.06 |
| speed_monotonic | yes | yes |
| max_thrust_fraction | 1.00 | 1.00 |
| profile_unchanged | yes | yes |

**brake_noretro**

| metric | c3 | c4 |
|---|---|---|
| speed_at_activation | 14.97 | 14.97 |
| stopping_distance | 74.67 | 74.67 |
| stopping_time | 10.62 | 10.62 |
| peak_sternward_thrust | 1.50 | 1.50 |
| speed_monotonic | yes | yes |
| max_thrust_fraction | 0.45 | 0.45 |
| profile_unchanged | yes | yes |

**crab10**

| metric | c3 | c4 |
|---|---|---|
| arrival_time | 5.23 | 5.23 |
| displacement | 10.15 | 10.15 |
| final_miss | 0.15 | 0.15 |
| peak_speed | 3.07 | 3.07 |
| max_line_deviation | 0.02 | 0.02 |
| yaw_change | -11.98 | -11.98 |
| max_thrust_fraction | 0.60 | 0.60 |
| profile_unchanged | yes | yes |

**clear**

| metric | c3 | c4 |
|---|---|---|
| arrival_time | 16.25 | 23.40 |
| final_miss | 0.06 | 0.17 |
| max_off_mesh | 0.00 | 0.00 |
| bow_to_path_last_over_5deg | 7.58 | 23.37 |
| turn_sign_flips_last_10s | 1 | 0 |
| leg_max_bow_travel | 179.24 | 79.17 |
| leg_mean_bow_travel | 42.46 | 38.49 |
| leg_share_under_5deg | 0.22 | 0.06 |
| leg_settled_under_5deg | n/a | n/a |
| max_thrust_fraction | 1.00 | 0.86 |
| profile_unchanged | yes | yes |

**route**

| metric | c3 | c4 |
|---|---|---|
| arrival_time | 26.87 | n/a |
| final_miss | 0.04 | 76.40 |
| min_hull_gap | 5.07 | -1.50 |
| max_off_mesh | 1.93 | 7.11 |
| max_bow_to_path | 103.64 | 103.64 |
| bow_to_path_last_over_5deg | 16.98 | 11.63 |
| turn_sign_flips_last_10s | 2 | 1 |
| leg_max_bow_travel | 168.07 | 104.68 |
| leg_mean_bow_travel | 34.54 | 53.05 |
| leg_share_under_5deg | 0.16 | 0.09 |
| leg_settled_under_5deg | n/a | n/a |
| max_thrust_fraction | 1.00 | 0.64 |
| profile_unchanged | yes | yes |

**a2_5**

| metric | c3 | c4 |
|---|---|---|
| arrived | no | no |
| arrival_time | n/a | n/a |
| min_hull_gap | 2.45 | 2.45 |
| max_off_mesh | 0.38 | 0.37 |
| contact | none | none |
| max_thrust_fraction | 0.95 | 0.95 |
| profile_unchanged | yes | yes |

c3: 5.02 planning (240.0, -201.0); 7.30 declined (240.0, -201.0): maneuver planning failed: no safe maneuver found within 120 s of predicted flight (route: centre enters the no-go zone at (221.1, -198.5))

c4: 5.02 planning (240.0, -201.0); 6.87 declined (240.0, -201.0): maneuver planning failed: no safe maneuver found within 120 s of predicted flight (route: centre enters the no-go zone at (220.8, -200.6))

**a2_6**

| metric | c3 | c4 |
|---|---|---|
| arrived | no | yes |
| arrival_time | n/a | 17.32 |
| min_hull_gap | 2.45 | 2.45 |
| max_off_mesh | 0.38 | 0.37 |
| contact | none | none |
| max_thrust_fraction | 0.95 | 1.00 |
| profile_unchanged | yes | yes |

c3: 6.02 planning (240.0, -201.0); 8.30 declined (240.0, -201.0): maneuver planning failed: no safe maneuver found within 120 s of predicted flight (route: centre enters the no-go zone at (222.0, -196.5))

c4: 6.67 accepted (240.0, -201.0): route; hazards [] of 65.2 m; resolved to (221.39, -210.08), 20.70 m from the click (nearest navigable point; 1 candidates tested, 1 path tests); 23.33 arrived at (221.4, -210.1) at 23.33 s

**queue**

| metric | c3 | c4 |
|---|---|---|
| activations | 0.32 / 1.32 / 1.82 | 0.32 / 1.32 / 1.82 |
| arrival_time | 15.90 | 22.98 |
| final_miss | 0.06 | 0.17 |
| max_thrust_fraction | 1.00 | 0.98 |
| profile_unchanged | yes | yes |

**crossover**

| metric | c3 | c4 |
|---|---|---|
| crossover_speed | 5.39 | 5.39 |
