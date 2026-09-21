# ADR-0022 — Dois donos por card e origem explícita

- **Estado:** proposta para a IMP-214
- **Data:** 21/09/2026

## Decisão

Cada oportunidade pode ter dois responsáveis independentes e opcionais:
`crc_owner_profile_id` para Atendimento (CRC) e `sales_owner_profile_id` para
Vendas. O papel CRC/Vendas pertence à atribuição do card, não cria um novo papel
em `crm.tenant_memberships`.

A elegibilidade para aparecer nos seletores é um campo separado,
`tenant_memberships.is_assignable`, `boolean not null default false`. O preenchimento
inicial marca memberships ativas `attendant` e preserva o perfil que já era dono
da Central. Isso não concede escrita: autorização continua em `crm.can_write` e
`public.client_users`.

A integridade usa FKs compostas por tenant e validação adicional de membership
ativa e assignable na RPC `crm_set_owner` e em trigger. A RPC recebe o papel
`crc` ou `sales` e um perfil nulo limpa apenas aquele responsável.

A origem é calculada no banco: `anuncio` quando pelo menos um de
`conversion_source`, `ctwa_clid` ou `meta_ad_id` está preenchido; caso contrário,
`organico`. O filtro de origem e os filtros de CRC/Vendas são aplicados de forma
idêntica no kanban, na lista e nas contagens.

## Motivo

Atendimento e fechamento são responsabilidades diferentes e podem estar com
pessoas distintas. Reutilizar memberships existentes evita um vocabulário novo de
papéis e separa claramente "pode escrever" de "pode receber uma atribuição".
Calcular origem a partir dos campos canônicos evita heurística no frontend e
mantém cards orgânicos visíveis sem inventar dados de anúncio.

## Fora de escopo

Ligar a agência da Impuls como assignable, alterar conversões, criar fonte de
nomes de anúncio ou mudar regras de frase da IMP-226.
