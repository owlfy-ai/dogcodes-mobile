<!-- Keep README languages aligned with the desktop phone-remote section. -->
<div align="center">

<img src="../../assets/branding/app-icon.png" alt="dog.codes" width="96" height="96" />

# dog.codes.mobile

**Comande seus agentes pelo celular**

<a href="../../README.md">English</a> · <a href="../../docs/i18n/README.zh-CN.md">简体中文</a> · <a href="../../docs/i18n/README.zh-TW.md">繁體中文</a> · <a href="../../docs/i18n/README.ja.md">日本語</a> · <a href="../../docs/i18n/README.ko.md">한국어</a> · <a href="../../docs/i18n/README.es.md">Español</a> · <a href="../../docs/i18n/README.fr.md">Français</a> · <a href="../../docs/i18n/README.de.md">Deutsch</a> · <strong>Português (Brasil)</strong>

</div>

Este projeto é o app móvel complementar para iOS e Android do [app dog.codes para PC](https://github.com/owlfy-ai/dogcodes) e requer o app para PC para funcionar.

Conecte seus computadores para continuar conversas, aprovar solicitações, revisar alterações, executar projetos e usar a área de trabalho remota. Os agentes rodam no seu computador com as contas e assinaturas que você já tem.

[dog.codes](https://dog.codes) · [App de desktop](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.pt-BR.md) · [Recursos](#phone) · [Desenvolvimento](../../docs/development.md)

## Agentes compatíveis no seu computador

Conecte os agentes que você já usa. As 12 integrações abaixo estão implementadas; modelos, aprovações, dados de uso e recuperação variam conforme o agente e sua versão. Primeiro, instale e entre na conta de cada agente usando suas ferramentas oficiais.

<p align="center">
  <a href="https://developers.openai.com/codex/"><img src="../../docs/images/readme/agents/codex.png" alt="Codex" height="36" /></a>
  <a href="https://code.claude.com/docs/en/overview"><img src="../../docs/images/readme/agents/claude-code.png" alt="Claude Code" height="36" /></a>
  <a href="https://cursor.com/"><img src="../../docs/images/readme/agents/cursor.png" alt="Cursor" height="36" /></a>
  <a href="https://www.kimi.com/"><img src="../../docs/images/readme/agents/kimi.png" alt="Kimi Code" height="36" /></a>
  <a href="https://grok.com/"><img src="../../docs/images/readme/agents/grok.png" alt="Grok Build" height="36" /></a>
  <a href="https://z.ai/"><img src="../../docs/images/readme/agents/zcode.png" alt="ZCode" height="36" /></a>
  <br />
  <a href="https://antigravity.google/"><img src="../../docs/images/readme/agents/antigravity.png" alt="Antigravity" height="36" /></a>
  <a href="https://www.codebuddy.ai/"><img src="../../docs/images/readme/agents/codebuddy.png" alt="CodeBuddy" height="36" /></a>
  <a href="https://pi.dev/"><img src="../../docs/images/readme/agents/pi.png" alt="Pi" height="36" /></a>
  <a href="https://opencode.ai/"><img src="../../docs/images/readme/agents/opencode.png" alt="OpenCode" height="36" /></a>
  <a href="https://github.com/deepseek-ai/deepseek-harness"><img src="../../docs/images/readme/agents/deepseek-harness.png" alt="DeepSeek Harness" height="36" /></a>
  <a href="https://kiro.dev/"><img src="../../docs/images/readme/agents/kiro.png" alt="Kiro" height="36" /></a>
</p>

<a id="phone"></a>

## Comande seus agentes pelo celular

**Deixe o notebook em casa. Seus agentes continuam trabalhando no seu computador enquanto o celular mantém o comando.**

Pareie um celular uma única vez e faça tudo abaixo de qualquer lugar. Seu código e seus agentes ficam no seu computador.

![Comande seus agentes pelo celular](../../docs/images/readme/en/phone-remote.png)

- **Continue ou inicie conversas.** Retome qualquer conversa do seu computador ou comece uma nova: escolha agente, modelo e nível de raciocínio, acompanhe a saída ao vivo e pesquise, fixe, arquive ou ramifique sessões.

  ![Continue ou inicie conversas.](../../docs/images/readme/en/switch-agent.png)

- **Aprove e responda.** Pedidos de permissão e perguntas dos agentes chegam ao celular com notificações push; um toque e o agente segue em frente. Cada aprovação é conferida com a execução original no seu computador.

  ![Aprove e responda.](../../docs/images/readme/en/permissions.png)

- **Revise e faça commit.** Veja as mudanças em cada pasta do projeto, prepare arquivos, peça a um agente que escreva a mensagem do commit e então confirme, envie, baixe ou sincronize. Navegue pelo histórico de commits e compare branches em modo somente leitura. Desfaça com um toque todas as mudanças de arquivos de uma rodada.

  ![Revise e faça commit.](../../docs/images/readme/en/git-changes.png)

- **Adicione projetos a partir do PC.** Navegue pelas pastas do seu computador e adicione uma como projeto sem voltar para a mesa.

  ![Adicione projetos a partir do PC.](../../docs/images/readme/en/add-project.png)

- **Execute comandos no terminal do PC.** Abra terminais em qualquer pasta do projeto e trabalhe no shell de verdade do seu computador.

  ![Execute comandos no terminal do PC.](../../docs/images/readme/en/terminal.png)

- **Execute o projeto e veja no celular.** Inicie as entradas de execução no computador e abra o app web em execução direto no celular.

  ![Execute o projeto e veja no celular.](../../docs/images/readme/en/run-project.png)

- **Navegue por arquivos e envie anexos.** Leia os arquivos do projeto e anexe arquivos e imagens às suas mensagens.

  ![Navegue por arquivos e envie anexos.](../../docs/images/readme/en/files-attachments.png)

- **Área de trabalho remota quando precisar.** Veja a tela do seu computador e toque, arraste, role, faça pinça, digite ou cole texto e imagens, com qualidade que se adapta à rede.

![Área de trabalho remota quando precisar.](../../docs/images/readme/en/remote-desktop.png)

### Como a conexão funciona

- Escaneie um QR code uma vez, sem precisar de conta. A conexão é criptografada de ponta a ponta. Pareie vários computadores, veja quais estão on-line e revogue um celular quando quiser pelo app de desktop.
- O celular se conecta diretamente quando pode e, se não der, usa o serviço de retransmissão do dog.codes, que apenas encaminha tráfego criptografado.
- Seu computador precisa ficar ligado, com o dog.codes aberto ou minimizado. Enquanto houver trabalho ou uma sessão remota ativa, o dog.codes pode impedir que o computador entre em suspensão automática; você pode desativar isso.
- A área de trabalho remota funciona com computadores macOS, Windows e Linux (X11 e Wayland); o sistema operacional pede as permissões de tela e entrada necessárias.

<a id="getting-started"></a>

## Primeiros passos

1. Configure o [app de desktop dog.codes](https://github.com/owlfy-ai/dogcodes/blob/main/docs/i18n/README.pt-BR.md), instale e entre em pelo menos um agente compatível e adicione as pastas dos seus projetos.
2. Mantenha o dog.codes aberto ou minimizado, abra **Connect phone** e escaneie o QR code com **Connect computer** no app do celular.
3. Escolha um computador e um projeto e continue uma conversa ou comece uma nova.

Ainda sem um computador por perto? Toque em **Ver um exemplo primeiro** na primeira tela para experimentar o app com um computador fictício; nada é conectado.

A interface do celular está disponível em 11 idiomas: português do Brasil, inglês, chinês simplificado e tradicional, japonês, coreano, francês, alemão, espanhol, russo e italiano. Para compilar o código, parear localmente, testar e consultar detalhes de implementação, veja o [guia de desenvolvimento](../../docs/development.md).

Os ícones dos agentes são compartilhados com o app de desktop; veja as [fontes e avisos](../../docs/images/readme/agents/README.md). Nomes de produtos e marcas pertencem aos respectivos proprietários.
