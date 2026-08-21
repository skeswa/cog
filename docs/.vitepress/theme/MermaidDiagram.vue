<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from "vue";
import { loadMermaid, mermaidConfig } from "./mermaid";

const props = defineProps<{
  diagramId: string;
  source: string;
}>();

const error = ref("");
const loading = ref(true);
const output = ref<HTMLElement>();
const graph = decodeURIComponent(props.source);

/**
 * Mermaid bakes colours into the SVG it emits, so a rendered diagram cannot
 * follow the appearance toggle the way stylesheet-driven content does. The
 * observer below re-renders on every change to the root element's class list,
 * which is where VitePress records the current appearance.
 */
let observer: MutationObserver | undefined;

async function render() {
  try {
    const dark = document.documentElement.classList.contains("dark");
    const mermaid = await loadMermaid();
    mermaid.initialize(mermaidConfig(dark));
    const { bindFunctions, svg } = await mermaid.render(props.diagramId, graph);
    if (output.value === undefined) return;

    output.value.innerHTML = svg;
    bindFunctions?.(output.value);
    error.value = "";
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : "The diagram could not be rendered.";
  } finally {
    loading.value = false;
  }
}

onMounted(async () => {
  // Mermaid measures label text while laying out nodes, so a webfont that
  // swapped in afterwards would leave every label clipped or overflowing.
  await document.fonts?.ready;
  await render();

  observer = new MutationObserver(() => {
    void render();
  });
  observer.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["class"],
  });
});

onBeforeUnmount(() => {
  observer?.disconnect();
});
</script>

<template>
  <figure class="mermaid-diagram" :aria-busy="loading">
    <p v-if="loading" class="mermaid-diagram__status">Rendering diagram…</p>
    <div ref="output" class="mermaid-diagram__output" :hidden="loading || error.length > 0"></div>
    <!-- A diagram that will not render still has to show its content: the
         source is the information and the picture was only ever a
         convenience. -->
    <div v-if="!loading && error" class="mermaid-diagram__error" role="alert">
      <p>{{ error }}</p>
      <pre><code>{{ graph }}</code></pre>
    </div>
  </figure>
</template>
