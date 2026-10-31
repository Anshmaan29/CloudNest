import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { boundedGraph, layout, FrameBudget, Graph } from "./model";
interface Options {
  mode: string;
  quality: string;
  reducedMotion: boolean;
  onSelect: (id: string) => void;
}
export function createUniverse(
  container: HTMLElement,
  input: unknown,
  options: Options,
) {
  const budget =
    options.quality === "low"
      ? 100
      : options.quality === "cinematic"
        ? 600
        : 300;
  const graph = boundedGraph(input, budget);
  const positioned = layout(graph);
  const orbit = options.mode === "orbit";
  let disposed = false;
  let flight: {
    position: THREE.Vector3;
    target: THREE.Vector3;
    endPosition: THREE.Vector3;
    endTarget: THREE.Vector3;
    started: number;
  } | null = null;
  const renderer = new THREE.WebGLRenderer({
    antialias: options.quality !== "low",
    alpha: false,
    powerPreference: "low-power",
  });
  renderer.setClearColor(0x05060a, 1);
  renderer.setPixelRatio(
    Math.min(
      devicePixelRatio,
      options.quality === "cinematic" ? 2 : options.quality === "low" ? 1 : 1.5,
    ),
  );
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  container.replaceChildren(renderer.domElement);
  const canvas = renderer.domElement;
  canvas.setAttribute(
    "aria-label",
    "Real saved knowledge relationships. Select a node, or use the accessible list.",
  );
  canvas.setAttribute("role", "img");
  const scene = new THREE.Scene();
  scene.fog = new THREE.FogExp2(0x05060a, 0.008);
  const camera = new THREE.PerspectiveCamera(45, 1, 0.1, 500);
  camera.position.set(
    0,
    3,
    orbit ? 29 : Math.max(24, Math.sqrt(graph.nodes.length) * 3.4),
  );
  const controls = new OrbitControls(camera, canvas);
  controls.enableDamping = !options.reducedMotion;
  controls.dampingFactor = 0.12;
  controls.minDistance = 5;
  controls.maxDistance = 180;
  controls.autoRotate = false;
  controls.listenToKeyEvents(container);
  scene.add(new THREE.AmbientLight(0xa9a8df, 1.8));
  const key = new THREE.DirectionalLight(0xd6e4ff, 3.1);
  key.position.set(8, 12, 16);
  scene.add(key);
  const pink = new THREE.PointLight(0xe88dcd, 25, 70);
  pink.position.set(-10, -3, 6);
  scene.add(pink);
  const pickables: THREE.Object3D[] = [];
  const ids: string[] = [];
  const positions = new Map<string, THREE.Vector3>();
  let core: THREE.Mesh | undefined;
  const geometries: THREE.BufferGeometry[] = [];
  const materials: THREE.Material[] = [];
  const textures: THREE.Texture[] = [];
  function label(text: string, p: THREE.Vector3) {
    const surface = document.createElement("canvas");
    surface.width = 512;
    surface.height = 80;
    const ctx = surface.getContext("2d");
    if (!ctx) return;
    ctx.fillStyle = "rgba(8,9,17,.88)";
    ctx.beginPath();
    ctx.roundRect(12, 8, 488, 62, 12);
    ctx.fill();
    ctx.strokeStyle = "rgba(180,164,235,.2)";
    ctx.stroke();
    ctx.fillStyle = "#e2ddf4";
    ctx.font = "25px system-ui";
    ctx.textAlign = "center";
    ctx.fillText(text.slice(0, 34), 256, 47);
    const texture = new THREE.CanvasTexture(surface);
    texture.colorSpace = THREE.SRGBColorSpace;
    textures.push(texture);
    const material = new THREE.SpriteMaterial({
      map: texture,
      transparent: true,
      depthWrite: false,
    });
    materials.push(material);
    const sprite = new THREE.Sprite(material);
    sprite.position.copy(p).add(new THREE.Vector3(0, -0.95, 0.1));
    sprite.scale.set(4.5, 0.7, 1);
    scene.add(sprite);
  }
  const glowGeometry = new THREE.BufferGeometry();
  const glowPositions: number[] = [],
    glowColors: number[] = [];
  const color = new THREE.Color();
  const glowMaterial = new THREE.ShaderMaterial({
    transparent: true,
    depthWrite: false,
    blending: THREE.AdditiveBlending,
    uniforms: { size: { value: options.quality === "low" ? 38 : 58 } },
    vertexShader:
      "attribute vec3 nodeColor; varying vec3 vColor; uniform float size; void main(){vColor=nodeColor;vec4 mv=modelViewMatrix*vec4(position,1.0);gl_Position=projectionMatrix*mv;gl_PointSize=clamp(size*35.0/-mv.z,3.0,95.0);}",
    fragmentShader:
      "varying vec3 vColor; void main(){float d=length(gl_PointCoord-vec2(.5))*2.0;float a=pow(max(0.0,1.0-d),2.8)*.5;gl_FragColor=vec4(vColor,a);}",
  });
  materials.push(glowMaterial);
  geometries.push(glowGeometry);
  function glow(position: THREE.Vector3, hex: number) {
    glowPositions.push(position.x, position.y, position.z);
    color.setHex(hex);
    glowColors.push(color.r, color.g, color.b);
  }
  if (!orbit && positioned.length) {
    const geometry = new THREE.SphereGeometry(
      1,
      options.quality === "low" ? 8 : 14,
      options.quality === "low" ? 6 : 10,
    );
    const material = new THREE.MeshStandardMaterial({
      roughness: 0.27,
      metalness: 0.12,
      emissive: 0x160e27,
      emissiveIntensity: 0.8,
    });
    geometries.push(geometry);
    materials.push(material);
    const mesh = new THREE.InstancedMesh(geometry, material, positioned.length);
    const object = new THREE.Object3D();
    positioned.forEach((node, index) => {
      const p = new THREE.Vector3(...node.position);
      positions.set(node.id, p);
      ids.push(node.id);
      object.position.copy(p);
      object.scale.setScalar(
        0.17 + Math.min(0.65, Math.sqrt(node.degree) * 0.12),
      );
      object.updateMatrix();
      mesh.setMatrixAt(index, object.matrix);
      mesh.setColorAt(index, new THREE.Color(node.color));
      glow(p, node.color);
    });
    mesh.instanceMatrix.needsUpdate = true;
    scene.add(mesh);
    pickables.push(mesh);
    for (const node of [...positioned]
      .sort((a, b) => b.degree - a.degree || a.id.localeCompare(b.id))
      .slice(0, options.quality === "low" ? 6 : 14))
      label(node.title ?? node.id, positions.get(node.id)!);
    const vertices: number[] = [];
    for (const edge of graph.edges) {
      const a = positions.get(edge.source),
        b = positions.get(edge.target);
      if (a && b) vertices.push(a.x, a.y, a.z, b.x, b.y, b.z);
    }
    const links = new THREE.BufferGeometry();
    links.setAttribute(
      "position",
      new THREE.Float32BufferAttribute(vertices, 3),
    );
    const lineMaterial = new THREE.LineBasicMaterial({
      color: 0xb57cba,
      transparent: true,
      opacity: 0.24,
      depthWrite: false,
    });
    geometries.push(links);
    materials.push(lineMaterial);
    scene.add(new THREE.LineSegments(links, lineMaterial));
  }
  const pulseMeshes: {
    mesh: THREE.Mesh;
    curve: THREE.CatmullRomCurve3;
    started: number;
  }[] = [];
  if (orbit) {
    const geometry = new THREE.IcosahedronGeometry(2.8, 4);
    const material = new THREE.ShaderMaterial({
      uniforms: { time: { value: 0 } },
      vertexShader:
        "varying vec3 n;varying vec3 v;uniform float time;void main(){vec3 p=position*(1.0+.015*sin(position.x*5.0+time*.4)*sin(position.y*4.0));vec4 mv=modelViewMatrix*vec4(p,1.0);n=normalize(normalMatrix*normal);v=-mv.xyz;gl_Position=projectionMatrix*mv;}",
      fragmentShader:
        "varying vec3 n;varying vec3 v;uniform float time;void main(){float rim=pow(1.0-abs(dot(normalize(n),normalize(v))),2.0);float filaments=pow(.5+.5*sin(n.x*65.0+n.y*32.0+sin(n.z*24.0+time*.2)),6.0);vec3 c=vec3(.065,.045,.15)+vec3(.55,.36,.92)*rim+vec3(.18,.48,.55)*filaments*.45;gl_FragColor=vec4(c,1.0);}",
    });
    geometries.push(geometry);
    materials.push(material);
    core = new THREE.Mesh(geometry, material);
    scene.add(core);
    glow(new THREE.Vector3(0, 0, 0), 0xb7a1ff);
    graph.clients.forEach((client, index) => {
      const a =
        (index * 2 * Math.PI) / Math.max(1, graph.clients.length) + 0.35;
      const p = new THREE.Vector3(
        Math.cos(a) * 10,
        Math.sin(a) * 6,
        Math.sin(a * 1.7) * 2,
      );
      positions.set("client:" + client.id, p);
      const geo = new THREE.SphereGeometry(0.6, 16, 12);
      const mat = new THREE.MeshStandardMaterial({
        color:
          client.status === "revoked" || client.status === "expired"
            ? 0x6e7188
            : 0x84d2e3,
        emissive: 0x244466,
        roughness: 0.24,
        metalness: 0.3,
      });
      const mesh = new THREE.Mesh(geo, mat);
      mesh.position.copy(p);
      mesh.userData.id = "client:" + client.id;
      scene.add(mesh);
      pickables.push(mesh);
      geometries.push(geo);
      materials.push(mat);
      glow(p, client.status === "configured" ? 0x84d2e3 : 0x8b8198);
      const curve = new THREE.CatmullRomCurve3([
        new THREE.Vector3(0, 0, 0),
        p
          .clone()
          .multiplyScalar(0.45)
          .add(new THREE.Vector3(0, 0, 3.5)),
        p,
      ]);
      const line = new THREE.BufferGeometry().setFromPoints(
        curve.getPoints(50),
      );
      const lineMat = new THREE.LineBasicMaterial({
        color: 0x9582cb,
        transparent: true,
        opacity: 0.4,
      });
      geometries.push(line);
      materials.push(lineMat);
      scene.add(new THREE.Line(line, lineMat));
      const latest = graph.events
        .filter((e) => e.clientId === client.id)
        .sort((x, y) => Date.parse(y.createdAt) - Date.parse(x.createdAt))[0];
      if (
        latest &&
        !options.reducedMotion &&
        Date.now() - Date.parse(latest.createdAt) < 12_000 &&
        Date.now() >= Date.parse(latest.createdAt)
      ) {
        const pulseGeo = new THREE.SphereGeometry(0.11, 8, 6);
        const pulseMat = new THREE.MeshBasicMaterial({ color: 0xceefff });
        const pulse = new THREE.Mesh(pulseGeo, pulseMat);
        scene.add(pulse);
        geometries.push(pulseGeo);
        materials.push(pulseMat);
        pulseMeshes.push({
          mesh: pulse,
          curve,
          started: Date.parse(latest.createdAt),
        });
      }
      label(client.clientName ?? client.id, p);
    });
  }
  glowGeometry.setAttribute(
    "position",
    new THREE.Float32BufferAttribute(glowPositions, 3),
  );
  glowGeometry.setAttribute(
    "nodeColor",
    new THREE.Float32BufferAttribute(glowColors, 3),
  );
  scene.add(new THREE.Points(glowGeometry, glowMaterial));
  const selectionGeometry = new THREE.RingGeometry(0.45, 0.49, 40);
  const selectionMaterial = new THREE.MeshBasicMaterial({
    color: 0xe6d4ff,
    side: THREE.DoubleSide,
    transparent: true,
    opacity: 0.8,
    depthWrite: false,
  });
  geometries.push(selectionGeometry);
  materials.push(selectionMaterial);
  const selection = new THREE.Mesh(selectionGeometry, selectionMaterial);
  selection.visible = false;
  scene.add(selection);
  const note = document.createElement("div");
  note.className = "graph-note";
  note.textContent = orbit
    ? graph.clients.length
      ? "Recorded, authorized client access · drag to orbit"
      : "No authorized client reads recorded for these memories"
    : "Saved relationships · drag to orbit · scroll to zoom";
  container.append(note);
  const render = (time: number) => {
    if (flight) {
      const t = Math.min(1, (time - flight.started) / 440),
        ease = t * t * (3 - 2 * t);
      camera.position.lerpVectors(flight.position, flight.endPosition, ease);
      controls.target.lerpVectors(flight.target, flight.endTarget, ease);
      if (t === 1) flight = null;
    }
    controls.update();
    if (core && core.material instanceof THREE.ShaderMaterial)
      core.material.uniforms.time.value = options.reducedMotion
        ? 0
        : time / 1000;
    for (const pulse of pulseMeshes) {
      const age = Date.now() - pulse.started;
      pulse.mesh.visible = age < 12_000;
      if (pulse.mesh.visible)
        pulse.mesh.position.copy(pulse.curve.getPoint((age % 2400) / 2400));
    }
    if (selection.visible) selection.quaternion.copy(camera.quaternion);
    if (
      options.quality !== "cinematic" &&
      pulseMeshes.length &&
      !pulseMeshes.some((p) => p.mesh.visible)
    )
      frames.setContinuous(false);
    renderer.render(scene, camera);
  };
  let framed = false;
  const frames = new FrameBudget(
    (fn) => requestAnimationFrame(fn),
    (id) => cancelAnimationFrame(id),
    render,
    (options.quality === "cinematic" && !options.reducedMotion) ||
      pulseMeshes.length > 0,
  );
  function resize() {
    if (disposed) return;
    const width = container.clientWidth,
      height = Math.max(1, container.clientHeight);
    camera.aspect = width / height;
    if (!framed && !orbit && positions.size) {
      const bounds = new THREE.Box3().setFromPoints([...positions.values()]);
      const center = bounds.getCenter(new THREE.Vector3()),
        size = bounds.getSize(new THREE.Vector3());
      const tangent = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
      const distance =
        Math.max(
          size.y / (2 * tangent),
          size.x / (2 * tangent * camera.aspect),
        ) *
          1.2 +
        size.z / 2 +
        3;
      controls.target.copy(center);
      camera.position
        .copy(center)
        .add(new THREE.Vector3(0, 1, Math.max(16, distance)));
      controls.update();
      framed = true;
    }
    camera.updateProjectionMatrix();
    renderer.setSize(width, height, false);
    frames.invalidate(2);
  }
  const observer = new ResizeObserver(resize);
  observer.observe(container);
  controls.addEventListener("change", () =>
    frames.invalidate(options.reducedMotion ? 1 : 18),
  );
  let pointerStart: [number, number] = [0, 0];
  const down = (e: PointerEvent) => {
    flight = null;
    pointerStart = [e.clientX, e.clientY];
  };
  const up = (e: PointerEvent) => {
    if (
      Math.hypot(e.clientX - pointerStart[0], e.clientY - pointerStart[1]) > 6
    )
      return;
    const rect = canvas.getBoundingClientRect();
    const mouse = new THREE.Vector2(
      ((e.clientX - rect.left) / rect.width) * 2 - 1,
      (-(e.clientY - rect.top) / rect.height) * 2 + 1,
    );
    const ray = new THREE.Raycaster();
    ray.setFromCamera(mouse, camera);
    const hit = ray.intersectObjects(pickables, false)[0];
    if (hit) {
      const id =
        hit.instanceId === undefined
          ? hit.object.userData.id
          : ids[hit.instanceId];
      if (typeof id === "string") {
        focus(id);
        options.onSelect(id);
      }
    }
  };
  canvas.addEventListener("pointerdown", down);
  canvas.addEventListener("pointerup", up);
  function focus(id: string) {
    const target = positions.get(id);
    if (!target) return;
    const direction = camera.position.clone().sub(controls.target).normalize();
    if (!direction.length()) direction.set(0, 0, 1);
    const destination = target
      .clone()
      .add(direction.multiplyScalar(orbit ? 12 : 8));
    if (options.reducedMotion) {
      controls.target.copy(target);
      camera.position.copy(destination);
    } else
      flight = {
        position: camera.position.clone(),
        target: controls.target.clone(),
        endPosition: destination,
        endTarget: target.clone(),
        started: performance.now(),
      };
    selection.position.copy(target);
    selection.visible = true;
    frames.invalidate(options.reducedMotion ? 1 : 30);
  }

  const visibility = () =>
    frames.setActive(!document.hidden && document.hasFocus());
  document.addEventListener("visibilitychange", visibility);
  window.addEventListener("blur", visibility);
  window.addEventListener("focus", visibility);
  resize();
  visibility();
  return {
    focus,
    setActive: (active: boolean) =>
      frames.setActive(active && !document.hidden),
    dispose() {
      if (disposed) return;
      disposed = true;
      frames.dispose();
      observer.disconnect();
      controls.dispose();
      canvas.removeEventListener("pointerdown", down);
      canvas.removeEventListener("pointerup", up);
      document.removeEventListener("visibilitychange", visibility);
      window.removeEventListener("blur", visibility);
      window.removeEventListener("focus", visibility);
      for (const geometry of geometries) geometry.dispose();
      for (const material of materials) material.dispose();
      for (const texture of textures) texture.dispose();
      scene.clear();
      renderer.dispose();
      renderer.forceContextLoss();
      container.replaceChildren();
    },
  };
}
