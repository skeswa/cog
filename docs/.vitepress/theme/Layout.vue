<script setup lang="ts">
import DefaultTheme from "vitepress/theme";

import CogMark from "./CogMark.vue";

/**
 * The default layout with the Cog mark dropped into the navigation title.
 *
 * `nav-bar-title-before` renders inside the same anchor as the site title, so
 * the mark and the wordmark move, wrap, and highlight as one lockup, and the
 * anchor keeps the single accessible name it already had. Filling the slot is
 * the only reason this wrapper exists; everything else is the stock theme.
 *
 * The alternative — `themeConfig.logo` — would render the mark through an
 * `<img>`, where it could neither pick up the brand custom properties across
 * the light and dark palettes nor animate on hover.
 */
const { Layout } = DefaultTheme;
</script>

<template>
  <Layout>
    <template #nav-bar-title-before>
      <CogMark />
    </template>
  </Layout>
</template>
