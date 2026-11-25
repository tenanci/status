# Status da Tenanci

Checagem automática dos serviços da Tenanci a cada 5 minutos, rodando no GitHub Actions (fora da infraestrutura da
Tenanci, então avisa mesmo se ela cair inteira).

- **O que é checado:** `checks.json` (painel, API, documentação e o proxy dos domínios).
- **Quando algo cai:** a checagem repete 20 s depois; se continuar falhando, abre uma issue "🔴 … fora do ar" (o
  GitHub avisa por e-mail quem acompanha o repositório) e fecha sozinha quando o serviço volta.
- **Página de status:** `docs/index.html` (GitHub Pages), que lê `docs/status.json`.
- **Manter vivo:** o GitHub desliga agendamentos de repositórios sem atividade há 60 dias; por isso o `status.json`
  é gravado pelo menos uma vez por dia.
