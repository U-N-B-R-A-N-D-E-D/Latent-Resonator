/* vite-env.d.ts - Vite client types */
/// <reference types="vite/client" />

declare module '*.css' {
  const content: string;
  export default content;
}
