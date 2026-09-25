import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Prosio Backend",
  description: "Prosio dictation backend — API only.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
