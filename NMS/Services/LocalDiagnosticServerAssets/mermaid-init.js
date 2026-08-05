// useMaxWidth: false -- raised directly ("the diagram font is small and i
// can't do cmd+ to expand"): Mermaid's default shrinks the SVG to fit its
// container's own width, which is why page zoom didn't help -- it was
// already scaled down, not just small. Rendering at natural size instead,
// with a larger base font, and letting .diagram-card's own horizontal
// scroll (style.css) handle whatever doesn't fit.
mermaid.initialize({
  startOnLoad: true,
  theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
  themeVariables: { fontSize: '18px' },
  flowchart: { useMaxWidth: false }
});

