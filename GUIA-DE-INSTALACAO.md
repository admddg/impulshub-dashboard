# ImpulsHub — Guia de instalação (passo a passo)

Feito pra quem é de marketing e está começando com código. Segue na ordem, sem pular.
Cada bloco de `código cinza` é um comando: copia, cola no terminal, aperta Enter.

---

## Antes de começar

Você já tem o Node.js instalado (confirmamos com `node --version`). 

Você vai precisar de um **editor de código** pra abrir e colar os arquivos.
Recomendo o **VS Code** (gratuito): https://code.visualstudio.com — baixa e instala.

Tenha em mãos os dois valores do Supabase:
- **Project URL** (ex: `https://abcdefgh.supabase.co`)
- **Publishable / anon key** (a chave longa, NÃO a secret)

---

## Passo 1 — Colocar a pasta do projeto no lugar

Você recebeu a pasta `impuls-app` com todos os arquivos prontos.
Coloca ela num lugar fácil, tipo a Área de Trabalho (Desktop) ou Documentos.

Abre o **VS Code** → menu **File > Open Folder** → seleciona a pasta `impuls-app`.
Você vai ver todos os arquivos na barra lateral esquerda.

---

## Passo 2 — Abrir o terminal dentro do VS Code

No VS Code, menu **Terminal > New Terminal**. 
Abre uma telinha na parte de baixo — é ali que você digita os comandos.
Ela já vai estar "dentro" da pasta do projeto, então pode digitar direto.

---

## Passo 3 — Instalar as peças do projeto

Digita e Enter (vai baixar as ferramentas; demora 1-2 min na primeira vez):

```
npm install
```

Quando terminar, aparece de volta a linha pra digitar. Deu certo.

---

## Passo 4 — Conectar ao seu Supabase (as chaves)

Na barra lateral, tem um arquivo chamado **`.env.local.example`**.

1. Clica com o botão direito nele → **Rename** (Renomear) → tira o `.example`,
   deixando só **`.env.local`**
2. Abre esse arquivo `.env.local`
3. Substitui os valores de exemplo pelos SEUS dois valores do Supabase:

```
NEXT_PUBLIC_SUPABASE_URL=https://SEU-PROJETO.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=cola-sua-chave-publishable-aqui
```

4. Salva (Ctrl+S / Cmd+S)

> Esse arquivo NÃO vai pro GitHub (está protegido no .gitignore), suas chaves ficam só na sua máquina.

---

## Passo 5 — Rodar o app na sua máquina

Digita e Enter:

```
npm run dev
```

Vai aparecer algo como:

```
▲ Next.js 14.2.5
- Local: http://localhost:3000
```

Abre o navegador e vai em **http://localhost:3000**

Você vai ver a **tela de login**. Entra com o usuário de teste que você já criou:
- **E-mail:** cliente.royal@teste.com
- **Senha:** (a que você definiu pra ele)

Se tudo estiver certo, você cai no **dashboard da Royal Odontologia** com os dados reais. 🎉

---

## Se algo der errado

**"command not found: npm"** → o Node não foi instalado direito. Reinstala de nodejs.org e
reinicia o VS Code.

**Tela de login aparece mas não entra** → confere se o e-mail/senha estão certos, e se as
chaves no `.env.local` estão coladas sem espaços sobrando.

**Dashboard aparece mas sem números / erro no console** → provável nome de coluna diferente.
Aperta F12 no navegador, aba "Console", e me manda o que aparecer em vermelho.

**Mudou o `.env.local` e não atualizou** → para o app (Ctrl+C no terminal) e roda `npm run dev`
de novo. Mudança de chave exige reiniciar.

---

## Como parar e voltar depois

- **Parar:** no terminal, aperta `Ctrl + C`
- **Voltar:** abre a pasta no VS Code, terminal novo, `npm run dev` de novo
  (o `npm install` só precisa uma vez; o `.env.local` já fica salvo)

---

## Estrutura dos arquivos (pra você se localizar)

```
impuls-app/
├── app/
│   ├── globals.css        → todas as cores e estilos (marca Impuls)
│   ├── layout.tsx         → base do site (fonte, título)
│   ├── page.tsx           → decide se manda pro login ou dashboard
│   ├── login/page.tsx     → tela de login
│   └── dashboard/page.tsx → a tela Visão Geral (lê a v_client_performance_daily)
├── components/
│   └── KpiCard.tsx        → o card de indicador reutilizável (com delta)
├── lib/
│   ├── supabase.ts        → conexão com o banco
│   └── utils.ts           → cálculos de data, período e formatação
├── public/
│   └── logo-impuls.png    → o logo que aparece no topo e no login
└── .env.local            → suas chaves (você cria no Passo 4)
```

Quando quiser mexer numa cor, é no `globals.css` (lá em cima, nos `--nomes`).
Quando quiser mudar um texto, é no arquivo `.tsx` da tela correspondente.
