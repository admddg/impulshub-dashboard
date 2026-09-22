Tarefa: escrever ADR e task file da IMP-215 (nao implementar codigo, nao abrir PR de codigo) no
mesmo formato/padrao ja usado em docs/task-files/TASK-IMP-217.md e docs/task-files/TASK-IMP-218.md
(leia os dois primeiro, como modelo de rigor e de secoes).

Objetivo da IMP-215: quem consome public.conversion_outbox de verdade e manda para Meta CAPI e
Google (Data Manager API), hoje ninguem consome as linhas status=pending que a IMP-216/217/218
comecam a criar quando crm_emits_conversions estiver ligado no futuro.

Leia antes de escrever, para nao inventar requisito:
- docs/adr/ADR-0017-entregar-crm-com-conversoes-desligadas.md (contexto completo da fila pendente)
- docs/N8N_WORKFLOWS_INTELIGENCIA_ACUMULADA.md secoes sobre 1.2 (dispatcher Meta) e 1.3 (dispatcher
  Google) — como o n8n hoje consome conversion_outbox para os clientes GHL, colunas que le, como
  marca status como sent/failed, retry, idempotencia
- docs/ROADMAP.md secao sobre IMP-215
- docs/task-files/TASK-IMP-218.md (decisoes ja tomadas la sobre route/meta_event_name NULL em linha
  Google, plataformas google_ads/meta) — a IMP-215 tem que consumir exatamente o que a 218 produz
- definicao viva de public.conversion_outbox em producao (SOMENTE LEITURA, mtxnwtqwfagjzkvgsncs):
  colunas, status possiveis, index/constraints, quantas linhas pending/sent/failed existem hoje
  (separando por platform e por source_system se a coluna existir) — para dimensionar o volume

Perguntas que o objetivo real do Head e do Caio: dado que o n8n 1.2/1.3 ja consomem
conversion_outbox HOJE para os clientes GHL (o fluxo existente, nao mexido pela IMP-216/230),
avalie e registre no ADR/task file, sem decidir sozinho, as opcoes:
(a) IMP-215 e so uma extensao do MESMO consumidor n8n existente (1.2/1.3), ajustado para tambem
pegar linhas source_system='impuls_crm' (que hoje ele ja deveria pegar, se filtra so por status e
nao por source_system — confirmar lendo o workflow/documentacao);
(b) IMP-215 precisa de um dispatcher novo e separado, especifico para o CRM;
(c) alguma combinacao.
Declare qual e a resposta mais provavel dada a leitura, e o que falta confirmar com o Caio antes de
comecar a implementar (Precisa do Caio/Coordenador antes de implementar).

Saida esperada: docs/adr/ADR-0026-consumidor-conversion-outbox.md (ou proximo numero livre — confira
antes) e docs/task-files/TASK-IMP-215.md, seguindo exatamente o modelo:
# IMP-XXX — <titulo>
Objetivo (1 frase):
Decisoes ja tomadas (nao reabrir):
Escopo (o que fazer):
Fora de escopo (o que NAO fazer):
Base em producao a ler antes (objetos, funcoes, politicas):
Arquivos previstos:
Criterios de aceite (verificaveis, com numero):
Testes obrigatorios:
Riscos conhecidos:
Entrega: PR draft, relatorio em 3 blocos, migration + rollback + APLICAR + gate + aceite (se banco)
Escalar ao Head se: <condicoes>
Precisa do Caio/Coordenador ANTES de implementar: <lista>

Regra: onde ha decisao em aberto (especialmente a pergunta (a)/(b)/(c) acima e qualquer coisa sobre
o workflow n8n que voce nao conseguir confirmar por falta de acesso direto), escreva PENDENTE e liste
em "Precisa do Caio/Coordenador". Nao toque em producao, nao faca DDL, nao abra branch de banco.
IMPORTANTE: o objetivo real deste turno e o Head e o Caio avaliarem o TAMANHO da entrega antes de
decidir comecar a implementar — capriche na estimativa de escopo e nos riscos, mais do que em
detalhe de SQL.

Ao final, commit na branch atual (docs/imp-215-taskfile) e abra PR draft para main com
gh pr create --draft. Relate em 3 blocos (verificado rodando / correto por construcao / nao bateu)
ao final do log.
