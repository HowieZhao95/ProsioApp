export default function Home() {
  return (
    <main style={{ fontFamily: "system-ui, sans-serif", padding: "2rem", maxWidth: 640 }}>
      <h1>Prosio Backend</h1>
      <p>This is the Prosio dictation backend. It exposes a JSON API only — see docs/API.md.</p>
      <ul>
        <li>
          <code>GET /api/health</code>
        </li>
        <li>
          <code>POST /api/auth/dev</code>
        </li>
        <li>
          <code>POST /api/transcribe</code>
        </li>
        <li>
          <code>GET|POST /api/usage</code>
        </li>
        <li>
          <code>GET|PUT /api/dictionary</code>
        </li>
      </ul>
    </main>
  );
}
