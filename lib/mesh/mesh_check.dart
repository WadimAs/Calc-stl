import 'dart:typed_data';

import 'weld.dart';

/// Topology problems that make the weight unreliable.
class MeshReport {
  final int triangles;
  final int openEdges; // edges with a single face: holes in the surface
  final int nonManifoldEdges; // edges shared by 3+ faces
  final int flippedEdges; // neighbours with opposite winding
  final int degenerate; // zero-area faces
  final int shells; // connected parts

  const MeshReport({
    required this.triangles,
    required this.openEdges,
    required this.nonManifoldEdges,
    required this.flippedEdges,
    required this.degenerate,
    required this.shells,
  });

  bool get isWatertight => openEdges == 0 && nonManifoldEdges == 0;
  bool get hasProblems => !isWatertight || flippedEdges > 0;
}

MeshReport checkMesh(Float32List t) {
  final n = t.length ~/ 9;
  if (n == 0) {
    return const MeshReport(triangles: 0, openEdges: 0, nonManifoldEdges: 0, flippedEdges: 0, degenerate: 0, shells: 0);
  }
  final (vid, nv) = weldVertices(t);

  // Every directed edge as (undirected key << 1 | direction), sorted.
  final edges = Int64List(n * 3);
  final edgeTri = Int32List(n * 3);
  int ne = 0;
  int degenerate = 0;
  for (int k = 0; k < n; k++) {
    final a = vid[k * 3], b = vid[k * 3 + 1], c = vid[k * 3 + 2];
    if (a == b || b == c || a == c) {
      degenerate++;
      continue;
    }
    for (final (p, q) in [(a, b), (b, c), (c, a)]) {
      final lo = p < q ? p : q, hi = p < q ? q : p;
      edges[ne] = ((lo * nv + hi) << 1) | (p < q ? 0 : 1);
      edgeTri[ne] = k;
      ne++;
    }
  }
  final order = List<int>.generate(ne, (i) => i)..sort((x, y) => edges[x].compareTo(edges[y]));

  // Union-find over faces joined by edges, for the number of shells.
  final parent = Int32List.fromList(List<int>.generate(n, (i) => i));
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  int open = 0, nonManifold = 0, flipped = 0;
  int i = 0;
  while (i < ne) {
    final key = edges[order[i]] >> 1;
    int j = i, d0 = 0, d1 = 0;
    while (j < ne && edges[order[j]] >> 1 == key) {
      if (edges[order[j]] & 1 == 0) {
        d0++;
      } else {
        d1++;
      }
      if (j > i) {
        final ra = find(edgeTri[order[i]]), rb = find(edgeTri[order[j]]);
        if (ra != rb) parent[ra] = rb;
      }
      j++;
    }
    final count = j - i;
    if (count == 1) {
      open++;
    } else if (count > 2) {
      nonManifold++;
    } else if (d0 != 1 || d1 != 1) {
      flipped++;
    }
    i = j;
  }

  final roots = <int>{};
  for (int k = 0; k < n; k++) {
    final a = vid[k * 3], b = vid[k * 3 + 1], c = vid[k * 3 + 2];
    if (a == b || b == c || a == c) continue;
    roots.add(find(k));
  }
  return MeshReport(
    triangles: n,
    openEdges: open,
    nonManifoldEdges: nonManifold,
    flippedEdges: flipped,
    degenerate: degenerate,
    shells: roots.length,
  );
}
