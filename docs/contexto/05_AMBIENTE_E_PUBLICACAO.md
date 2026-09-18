# ImpulsHub — Ambiente e publicação

> Fluxo operacional: como o ambiente funciona, como empacotar, validar e
> publicar.

---

## ⚠️ O ambiente reseta entre sessões

**Este é o ponto mais importante deste arquivo.** O sistema de arquivos do
Claude é limpo entre conversas. Não existe continuidade de arquivos.

**No começo de cada sessão que envolva código:**

1. Restaurar o projeto do último zip entregue
2. `npm install`
3. Reaplicar edições
4. `npm run build` antes de empacotar

```bash
cd /home/claude && rm -rf impuls-app && mkdir impuls-app && cd impuls-app
unzip -q /mnt/user-data/outputs/impuls-app-vXX.zip
npm install
```

---

## Validar o build

**Sempre antes de empacotar.** O build valida TypeScript e detecta erros
que passam despercebidos.

```bash
cd /home/claude/impuls-app
NEXT_PUBLIC_SUPABASE_URL=https://exemplo.supabase.co \
NEXT_PUBLIC_SUPABASE_ANON_KEY=chave \
npm run build
```

As variáveis fake servem só para o build passar — o app real usa o
`.env.local` do usuário.

---

## Empacotar

```bash
cd /home/claude/impuls-app
rm -rf node_modules/.cache .next tsconfig.tsbuildinfo
zip -rq /home/claude/impuls-app-vXX.zip . -x "node_modules/*" ".next/*" "*.DS_Store"
```

Depois usar `present_files` para entregar.

---

## Validar SQL antes de entregar

Quando o trabalho envolver SQL (raro — normalmente é o time de banco, mas
acontece):

```bash
pip install pglast --break-system-packages -q
python3 -c "
import pglast
try:
    pglast.parse_sql(open('arquivo.sql').read())
    print('✓ SQL válido')
except Exception as e:
    print('✗ ERRO:', e)
"
```

---

## Instalação (lado do usuário)

1. Descompactar o zip
2. Copiar o `.env.local` (a URL do Supabase vai **sem** `/rest/v1`)
3. `npm install`
4. `npm run dev` para testar

---

## Publicar

**Erro clássico:** rodar `git` dentro da pasta do zip descompactado. O
`.git` está na pasta do **repositório**, não no zip.

**Fluxo correto:**

1. Abrir a pasta do repositório (a que tem `.git` — provavelmente
   `impulshub-dashboard` ou similar)
2. Copiar **todo** o conteúdo do zip descompactado para dentro dela,
   substituindo os arquivos
3. No terminal, **dentro da pasta do repositório**:

```bash
npm install
npm run build
git status          # conferir o que vai subir
git add .
git commit -m "descrição da mudança"
git push
```

A Vercel faz deploy automático via webhook. Acompanhar em vercel.com →
Deployments até ficar verde.

**Se perder a pasta do repositório:** procurar por uma pasta que contenha
`.git` (pode estar oculta — habilitar "Mostrar itens ocultos" no Explorer).

**`.env.local` está no `.gitignore`** — confirmado, nunca aparece no
`git status`.

---

## Testar performance de verdade

`npm run dev` usa React StrictMode, que monta componentes duas vezes e
gera chamadas duplicadas que **não existem em produção**.

Para medir performance real e contar chamadas de RPC:

```bash
npm run build
npm run start
```

Depois abrir a aba **Network** do navegador e conferir:
- `get_client_overview_v2` — 2× ao abrir (atual + anterior)
- `get_meta_ads_summary_v2` com `account` — 1× ao abrir a aba Meta
- Trocar de sub-aba e voltar — **zero** chamadas novas (cache)

---

## Documentação no repositório

O repositório mantém `docs/` com:

```
docs/README.md
docs/ARQUITETURA.md
docs/BANCO_DE_DADOS.md
docs/DIARIO_PROJETO.md
docs/N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md
docs/sql/                  scripts aplicados
```

Esses documentos são a versão "no repositório" do conhecimento. Os
arquivos deste Project são a versão "para o Claude" — mais densa, focada
em decisões e armadilhas.

**Manter os dois sincronizados** quando houver mudança estrutural.

---

## Divisão de responsabilidade

| Área | Quem cuida |
|---|---|
| Banco de dados, views, RPCs | Usuário + outro colaborador |
| Workflows n8n, sync de mídia | Usuário + outro colaborador |
| **Frontend** | **Usuário + Claude (aqui)** |
| Documentação | Ambos |

**Implicação prática:** mudanças de banco chegam prontas via documento ou
contrato. Meu papel é consumir corretamente, apontar inconsistências, e
**pedir** ao time quando algo não existe — nunca criar workaround que
recrie lógica de banco no frontend.

---

## Formato de entrega

Cada entrega inclui:

1. **O zip** com build validado
2. **Resumo do que mudou** — objetivo, sem enfeite
3. **Pontos que merecem teste especial** — especialmente quando envolve
   número que o cliente vê
4. **O que ficou de fora e por quê** — decisões conscientes explicitadas

Quando envolver mudança de metodologia ou número visível: **apresentar o
plano e esperar aval antes de codificar.**
