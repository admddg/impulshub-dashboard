# ADR-0024 — Formulário do site (captação Google Ads) sem depender do GHL

- **Status:** proposta para a IMP-230
- **Data:** 22/09/2026
- **Decide:** Caio

## Contexto

Hoje **não existe nenhuma porta pública e anônima** de entrada no ImpulsHub. Todo
lead entra "ao vivo pelo webhook" do WhatsApp (Stevo), autenticado por uma chave
por instância (`stevo_instances`), consumido pelo parser (`crm.stevo_parse_messages`).

Cliente novo com Google Ads precisa de formulário no próprio site. O formulário
não fala com WhatsApp: ele precisa criar um contato e um card diretamente no
CRM, carregando `gclid`/`gbraid`/`wbraid` e UTMs — os mesmos campos que a
ADR-0023 (IMP-216) deixou de fora de propósito, porque dependiam desta ADR.

Isso é qualitativamente diferente de tudo que already existe no sistema: é a
**primeira superfície pública e anônima de escrita**. Todo o resto (CRM, RPCs
`crm_*`, views `v_crm_*`) exige `authenticated` com sessão de usuário real.
Um formulário de site é preenchido por visitante anônimo, então precisa de
`anon` com algum caminho de escrita — e isso é justamente o tipo de coisa que
a IMP-213 passou uma rodada inteira consertando vazamento (ADR-0020: revogar
privilégio de `anon`/`public` sempre que uma função é recriada).

## Decisão

### 1. Não expor RPC de escrita direto ao PostgREST para `anon`

Em vez de conceder `EXECUTE` a `anon` numa função `SECURITY DEFINER` exposta
via `/rest/v1/rpc/...` (superfície difícil de limitar por IP, sem controle de
payload antes de chegar no Postgres), o formulário fala com uma **Edge
Function nova**, no mesmo padrão já provado do `stevo-ingest`:

- `supabase/functions/form-intake/index.ts`, `verify_jwt: false`;
- recebe `client_slug` (público, ex. `royal`) e `form_token` (segredo, um por
  cliente, gerado e não adivinhável) via body ou querystring;
- valida o token contra `public.clients_base.form_intake_token` **antes** de
  tocar em qualquer tabela do CRM;
- roda com a chave de `service_role` **só dentro da function**, nunca exposta
  ao navegador;
- chama uma função `SECURITY DEFINER` no Postgres (`crm.intake_form_lead`) que
  faz a escrita de verdade, com todas as mesmas guardas (isolamento,
  `search_path=''`, revoke de `anon`/`public`/`authenticated` — só
  `service_role` executa).

`anon` **não ganha nenhum privilégio novo em tabela ou função do CRM**. Isso
mantém a regra da IMP-213/ADR-0020 intacta: nada novo exposto a anônimo além
da própria Edge Function, que já é a fronteira de validação.

### 2. Autenticação do formulário: token por cliente, não por chamada

`public.clients_base` ganha `form_intake_token uuid not null default
gen_random_uuid()`, único, gerado automaticamente para todo cliente. É o
token que vai embutido no HTML do formulário do site (visível no código-fonte
da página — é esperado, como uma chave pública de formulário). Vaza sem
problema maior porque:

- ele só permite **criar** lead (insert), nunca ler dado de outro cliente;
- pode ser rodado (`update ... set form_intake_token = gen_random_uuid()`)
  a qualquer momento pelo Caio se for abusado, sem precisar de migration.

### 3. Anti-abuso: limite por IP e por token, dentro da Edge Function

A Edge Function recebe o IP real da requisição (cabeçalho que o Supabase
injeta) e aplica um limite simples antes de chamar o Postgres: no máximo N
submissões por IP por janela de tempo, e no máximo M por `form_intake_token`
por janela de tempo, contra uma tabela pequena e própria
(`public.form_intake_rate_limit`, chave IP+token+janela, TTL curto). Passou do
limite: responde 429, não escreve nada. Isso é MVP — não é captcha, não é
detecção de bot sofisticada; é o mínimo para não deixar a porta escancarada.
Campo honeypot (campo escondido que humano não preenche e bot preenche) some
a submissão sem erro, sem escrever nada.

### 4. Dedupe: mesmo lead reenviando o formulário não duplica

O aceite precisa provar que reenviar a mesma submissão (mesmo telefone/e-mail
do mesmo cliente numa janela curta) não cria card duplicado — mesma lógica de
"no-op" que a IMP-216 já usa via índice de dedupe.

### 5. Origem Google chega ao card e ao dashboard

`crm.opportunities` ganha as colunas `gclid`, `gbraid`, `wbraid`, `utm_source`,
`utm_medium`, `utm_campaign`, `utm_content`, `utm_term` (texto, opcionais —
espelham as mesmas colunas que já existem em `events_normalized`, criadas
antes da ADR-0023). `crm.emit_opportunity_stage_event` (já mexida na IMP-216)
passa a carregar essas colunas no INSERT de `events_normalized` quando
presentes — fechando o "Google fica para IMP-230" que a IMP-216 deixou
registrado.

### 6. O card entra na etapa `lead`, sem dono, aberto

O formulário cria: um `crm.contacts` novo (ou reaproveita um existente do
mesmo cliente por telefone/e-mail, se já houver) e um `crm.opportunities` na
etapa `lead` do pipeline global vigente daquele tenant, sem
`crc_owner_profile_id`/`sales_owner_profile_id` (a agência atribui depois,
IMP-214 já resolveu o seletor). `conversion_source = 'google_ads'` quando
houver `gclid`; `'organic'` quando não houver nenhum parâmetro de campanha.

## Motivo

Cliente novo com Google Ads é a próxima entrega prometida (ADR-0023 já
avisou: "consumo da origem Google pelo formulário é a IMP-230, que depende
desta"). O jeito mais simples de não repetir o erro da 213 (privilégio
vazando para `anon`) é não inventar uma superfície de escrita nova exposta
direto ao Postgres — reusar o padrão que já existe e já foi testado em
produção (Edge Function + chave), só trocando "chave de instância WhatsApp"
por "chave de formulário".

## Consequências

- Duas coisas novas expostas à internet sem autenticação: a Edge Function
  `form-intake` e o token por cliente. Nenhuma delas expõe leitura — só
  criação de lead, e só do próprio cliente do token.
- `crm.opportunities` ganha 8 colunas nullable; não quebra nada existente.
- Variação **zero** para Royal, Central e QuickClean: eles não têm formulário
  de site nesta entrega (isso é decisão de negócio, fora desta ADR — o
  formulário só é instalado no site de cliente que pedir).
- O Caio precisa aprovar a aplicação em produção **e** revisar o texto/design
  do próprio formulário HTML antes de publicar no site do cliente — isso é
  entrega separada (o embed do formulário no site em si, fora do escopo desta
  IMP, que cobre só o backend).

## Fora de escopo

Captcha/detecção de bot avançada; o HTML/embed do formulário no site do
cliente (fica para quem sobe o site); autoatribuição de dono ao card criado
pelo formulário; notificação (e-mail/WhatsApp) para a agência quando um lead
novo chega pelo formulário; qualquer UI de configuração do
`form_intake_token` no painel (por ora, só SQL).
