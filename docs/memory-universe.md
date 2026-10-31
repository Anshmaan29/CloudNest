# Memory Universe

The universe is part of the authenticated companion console, not a permanent
native WebGL view. It reads `/api/v1/graph`; the server filters private, expired,
deleted and pending records before applying the node budget. Edges require both
endpoints to be visible. Owner graph reads cannot bury actual client activity.

Low displays up to 100 nodes at pixel ratio 1; Balanced up to 300 at 1.5;
Cinematic up to 600 at 2. The server caps saved edges at 2,000. Explore a project
to retrieve another bounded cluster. Category, source and UTC date filters apply
within the loaded set; the interface states that scope explicitly. Search and
keyboard-accessible node buttons focus the camera and open an inspector.

Galaxy uses instanced spheres, real-degree hubs, saved edges, metadata-derived
colors and a bounded set of labels. Orbit shows a Brain sphere and clients with
recorded access to visible memories. A configured authorization alone is not
reported as a successful provider connection. Pulses require an actual retrieved
event less than twelve seconds old; refreshing cannot create synthetic activity.

Three.js and OrbitControls are imported dynamically on 3D entry. Balanced uses
on-demand frames; Cinematic renders continuously only while open, visible and
focused. Reduced motion disables camera flights, damping and pulses. Closing or
switching views cancels frames, removes listeners and observers, disposes GPU
resources and releases the WebGL context. The accessible list remains usable
when loading or renderer setup fails.

Automated tests exercise budgets, deterministic layout, endpoint privacy,
category/source/date filtering, actual-access filtering and frame cancellation.
Local browser QA uses explicitly synthetic records written through the real
owner API to a disposable Workers/D1 runtime with a test-only fake Google
transport. It verifies the interface, not a live Google integration. Actual
browser checks found and fixed WebKit's requirement that animation frame
functions retain the window receiver. GPU throughput and resource measurements
must be recorded for the actual hardware/node budget before claiming targets.
