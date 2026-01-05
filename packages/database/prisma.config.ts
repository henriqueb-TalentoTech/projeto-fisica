import { defineConfig } from '@prisma/config';
import 'dotenv/config'; // <--- ADICIONE ESTA LINHA

// Check de segurança para você não ficar louco tentando debuggar
if (!process.env.DATABASE_URL) {
  throw new Error('Erro Crítico: DATABASE_URL não encontrada no .env do pacote database');
}

export default defineConfig({
  datasource: {
    url: process.env.DATABASE_URL,
  },
});
