<script>
  import '../app.css';
  import { base } from '$app/paths';
  let { children } = $props();
</script>

<nav class="bar">
  <b>Mjolnir</b>
  <a href="{base}/">Home</a>
  <a href="{base}/examples">Examples</a>
  <a href="{base}/api">API</a>
  <a href="https://github.com/hucancode/mjolnir">GitHub</a>
</nav>
<main>{@render children()}</main>
