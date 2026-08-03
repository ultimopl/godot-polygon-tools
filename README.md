# Polygon Tools

Plugin de editor para **Godot 4.7** que automatiza o rigging de `Polygon2D`.
Dado um `Polygon2D` e seu `Skeleton2D`, calcula os pesos de bone por vértice e
re-triangula a malha do polígono — sem precisar pintar peso à mão.

O plugin aparece como uma aba de dock **"Polygon Tools"** no lado direito do
editor (junto de Inspector/Node).

---

## Instalação

1. Copie a pasta `addons/polygon_tools/` para o seu projeto Godot.
2. Ative em **Project Settings → Plugins → Polygon Tools**.
3. A aba **Polygon Tools** aparece no dock direito.

---

## Como usar

1. Deixe o `Skeleton2D` na **pose de bind** (resete qualquer IK). O cálculo
   amostra a pose atual da tela — se o esqueleto estiver dobrado, os pesos saem
   dobrados junto.
2. Selecione o `Polygon2D` na cena.
3. Na aba, aponte o `Skeleton2D` e ajuste os parâmetros.
4. Use as ações do dock:

| Ação | O que faz |
|------|-----------|
| **Calculate Weights** | Calcula os pesos por vértice e grava os bones no `Polygon2D`. |
| **Smooth Weights** | Relaxa os pesos atuais (Laplaciano sobre a malha). Uma passada por clique; o slider controla a força. |
| **Recalculate Polygons** | Re-triangula os pontos via Delaunay, descartando triângulos fora do contorno. Não mexe nos pontos. |
| **Subdivide Mesh** | Divide cada aresta no ponto médio; os novos vértices herdam UV e peso interpolados. Mais densidade = deformação mais suave. |

Todas as ações são **undoáveis** (`Ctrl+Z`).

---

## Como funciona

O plugin é dividido em duas camadas, de propósito: a matemática é pura e
testável sem o editor.

### Solver de envelope (ativo)

`envelope_solver.gd` (`AutoWeightEnvelopeSolver`) usa um modelo de
**envelope de bone (cápsula)** — não resolve nenhuma malha:

- Cada bone vira um segmento (do bone até o bone filho, a direção visual do
  membro).
- Raio da cápsula: `radius = radius_scale * max(0.5 * comprimento, char_thickness)`,
  onde `char_thickness` é ~o percentil 90 da distância vértice→bone mais próximo
  (assim bones curtos e grossos ainda cobrem seus vértices).
- Peso por vértice por bone: `w = 1 - smoothstep(inner, outer, dist_ao_segmento)`,
  com `inner/outer = radius * (1 ∓ softness)`.
- O peso é pontuado pela distância **relativa** `d/radius`, então bones com
  cápsula menor não vencem por padrão.
- **Teste de visibilidade opcional** zera bones ocluídos (corta o vazamento de
  peso através de dobras do membro).
- Mantém os top-N bones por vértice, normaliza. Vértices que ficam todos zero
  caem para o bone mais próximo.

**Parâmetros:** `radius_scale`, `softness` (0 = nítido .. 1 = mistura larga),
`max_bones_per_vertex`, `use_visibility`.

**Trade-off:** não é ciente da forma da malha; um membro dobrado em ângulo agudo
pode vazar peso através da dobra (o teste de visibilidade mitiga).

### Solver de bone-heat (legado)

`bone_heat_solver.gd` (`AutoWeightBoneHeatSolver`) é o solver antigo de difusão
de calor (bone-heat), com Laplaciano cotangente (`linalg.gd`). **Não está mais
ligado ao dock**, mas é mantido pelos statics de geometria compartilhados
(reusados pelo solver de envelope) e por seus próprios testes.

### Invariantes não-óbvios (cada um foi um bug real)

- **Pesos só ligam a vértices existentes.** Os arrays de peso do `Polygon2D` são
  indexados 1:1 com `polygon`; não dá pra adicionar pontos internos de amostra
  sem mudar a malha.
- **`polygon` / `polygons` / `bones` precisam ter contagens de índice
  consistentes.** Se `polygons` ou `bones` referenciam índices além de
  `polygon.size()`, o Godot trava/crasha ao montar a malha.
- **Visibilidade é por amostragem do interior**, não por cruzamento de aresta —
  um teste estrito de segmento bloqueia bones cujo ponto mais próximo cai numa
  aresta de borda.

---

## Como pode melhorar

- **Ciência da forma da malha.** O solver de envelope ignora a topologia; um
  membro fortemente dobrado vaza peso pela dobra. Um solver baseado em difusão
  geodésica na malha resolveria isso de forma mais robusta que o teste de
  visibilidade atual.
- **Amostras internas de peso.** Hoje os pesos só ligam a vértices do polígono.
  Suportar pontos de amostra internos (via `internal_vertices`) daria gradientes
  mais suaves sem subdividir toda a malha.
- **Preview ao vivo.** Visualizar os pesos por bone com heatmap direto no
  viewport, antes de gravar, encurtaria muito o loop de ajuste.
- **Pesos independentes de pose.** Amostrar a pose de bind automaticamente
  (em vez de exigir reset manual de IK) evitaria a pegadinha nº 1.
- **Presets de parâmetro** por tipo de personagem (humanoide, quadrúpede, etc.).

---

## Próximos planos

- [ ] Preview de heatmap de peso no viewport.
- [ ] Auto-detecção da pose de bind (dispensar reset de IK manual).
- [ ] Solver geodésico opcional para membros dobrados.
- [ ] Publicar na Godot Asset Library.
- [ ] Documentação in-editor / tooltips nos parâmetros.

---

## Arquitetura dos arquivos

```
addons/polygon_tools/
├── plugin.gd            # EditorPlugin — registra o dock
├── autoweight_dock.gd   # UI do painel (construído em código, sem .tscn)
├── envelope_solver.gd   # solver ativo (envelope/cápsula)
├── bone_heat_solver.gd  # solver legado + statics de geometria compartilhados
├── linalg.gd            # Laplaciano cotangente + solver Gauss denso
├── mesh_subdivide.gd    # subdivisão de malha
└── plugin.cfg
```

---

## Licença

MIT.
