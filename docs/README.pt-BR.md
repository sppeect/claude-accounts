# claude-accounts

> Perfis de conta no estilo AWS CLI para o Claude Code.

[![CI](https://github.com/sppeect/claude-accounts/actions/workflows/ci.yml/badge.svg)](https://github.com/sppeect/claude-accounts/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](../LICENSE)

[English](../README.md) | **Português (Brasil)**

Use o Claude Code com várias contas — `claude --account work`, `claude --account personal` — em terminais diferentes ao mesmo tempo, com padrão por repositório via um arquivo `.claude-account` commitável.

Autocontido, com paridade total de funcionalidades em todos os shells:

- `src/ClaudeAccounts.psm1` — Windows PowerShell 5.1+
- `src/claude-accounts.sh` — bash 3.2+ / zsh (carregado via `source` no rc do shell), incluindo o Git Bash no Windows
- `src/cmd/` — shims finos para o Prompt de Comando (`cmd.exe`) que delegam ao módulo PowerShell

No Windows um único `install.ps1` configura os três — PowerShell, cmd e Git Bash — então `claude --account work` se comporta igual em todos.

## O problema

Você tem mais de uma conta Claude — uma de trabalho num plano de equipe e uma pessoal, ou uma conta por cliente — mas o Claude Code loga em exatamente uma por vez. Trocar significa deslogar e logar de novo, perder a sessão, e não existe mecanismo de perfis embutido ([anthropics/claude-code#30031](https://github.com/anthropics/claude-code/issues/30031)).

O `claude-accounts` dá a cada conta seu próprio diretório de configuração isolado (credenciais, settings, histórico, sessões) e um wrapper que escolhe o diretório certo a cada invocação — o mesmo modelo do `aws --profile`.

## Início rápido

### Instalação

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/sppeect/claude-accounts/main/install.sh | bash
```

Windows (PowerShell):

```powershell
iwr -useb https://raw.githubusercontent.com/sppeect/claude-accounts/main/install.ps1 | iex
```

Depois reinicie o shell (ou `source ~/.bashrc` / `. $PROFILE`).

### 30 segundos para duas contas

```bash
claude-account add work        # cria o perfil e abre o login no navegador
claude-account add personal    # faça login com a outra conta claude.ai

claude --account work          # este terminal roda a conta de trabalho...
claude --account personal      # ...enquanto outro terminal roda a pessoal

cd ~/code/projeto-cliente
claude-account bind work       # este repo (e subdiretórios) usa 'work' por padrão
claude                         # sem flag — resolve para 'work'

claude-account current         # mostra a conta efetiva e o porquê
```

Sua instalação existente fica intocada: ela é o perfil `default` (`~/.claude`), e o `claude` puro continua funcionando exatamente como antes.

## Comandos

| Comando | O que faz |
| --- | --- |
| `claude --account <nome> [...]` | Roda o Claude Code com a conta escolhida (alias `-a`, também `--account=<nome>`) |
| `claude-account list` | Lista todos os perfis, o e-mail logado em cada um, e marca o ativo |
| `claude-account add <nome>` | Cria um perfil (herdando ferramentas do default) e abre o login no navegador |
| `claude-account add <nome> --minimal` | Herda apenas o `settings.json` (sem skills/agents/conteúdo) |
| `claude-account add <nome> --no-login` | Cria sem logar (o login é pedido na primeira execução) |
| `claude-account add <nome> --path <dir>` | Cria um perfil cujo config dir fica num caminho customizado |
| `claude-account remove <nome> [--force]` | Apaga um perfil (`--force` obrigatório quando há dados de login) |
| `claude-account use <nome>` | Fixa uma conta neste terminal (`use default` para desfazer) |
| `claude-account bind <nome>` | Vincula o diretório atual a uma conta (escreve `.claude-account`) |
| `claude-account unbind` | Remove o vínculo do diretório atual |
| `claude-account migrate <nome> [--from <nome>]` | Copia ferramentas/conteúdo do default (ou `--from`) para um perfil (nunca credenciais) |
| `claude-account current` | Mostra a conta efetiva, seu login, diretório e qual regra a selecionou |
| `claude-account doctor` | Diagnostica a instalação em PowerShell, cmd e Git Bash |
| `claude-account version` | Imprime a versão instalada |

No Windows as opções são switches no estilo PowerShell: `-NoLogin`, `-Path <dir>`, `-Minimal`, `-From <nome>`, `-Force`.

O nome `default` é reservado para a instalação original e não pode ser criado nem removido.

### O que um perfil novo herda

O `add` copia as ferramentas e preferências da conta default para que um perfil novo já comece pronto para trabalhar: skills, agents, commands, plugins, `settings.json`, rules, output styles, temas, keybindings, além das suas sessões, projetos e histórico. Ele **nunca** copia o `.credentials.json` nem o arquivo de identidade, então cada perfil loga como a sua própria conta. Use `--minimal` para herdar só o `settings.json`, e `claude-account migrate` depois para puxar ferramentas para um perfil já criado. Arquivos já existentes no perfil nunca são sobrescritos.

## Resolução de conta

Da maior para a menor prioridade:

1. **Flag `--account` / `-a`** — aceita apenas antes do primeiro argumento posicional (ex.: `claude --account work -p "..."`). Tudo depois do primeiro argumento posicional é repassado intacto ao Claude Code, então `claude mcp add x -- cmd -a token` nunca tem seu `-a` sequestrado.
2. **`$CLAUDE_ACCOUNT`** — setada por `claude-account use` para a sessão atual do terminal.
3. **`$CLAUDE_CONFIG_DIR` setada externamente** — se você mesmo exportou a variável, o wrapper a honra exatamente como o binário puro faria (exibida como `(external)`).
4. **Arquivo `.claude-account`** — procurado do diretório atual para cima, como um `.nvmrc`. O primeiro arquivo encontrado decide; um arquivo vazio interrompe a busca (o vínculo de um diretório pai nunca vaza silenciosamente para baixo). Quebras de linha do Windows (CRLF) são toleradas.
5. **`default`** — a instalação original em `~/.claude`.

Na dúvida, `claude-account current` diz qual regra venceu e por quê.

## O arquivo `.claude-account`

Um arquivo de texto de uma linha contendo o nome de um perfil, exatamente como um `.nvmrc` contém uma versão do Node:

```bash
cd ~/code/projeto-cliente
claude-account bind work       # escreve .claude-account com o conteúdo "work"
git add .claude-account        # commite
```

Ele foi feito para ser commitado. Nomes de perfil são rótulos locais — cada pessoa do time roda `claude-account add work` uma vez com as próprias credenciais e, daí em diante, o mesmo arquivo commitado aponta cada um para a sua própria conta "work" dentro daquele repositório. Rode `bind` na raiz do repositório para valer em todos os subdiretórios.

## Como funciona

O Claude Code suporta oficialmente a variável de ambiente `CLAUDE_CONFIG_DIR` para realocar seu diretório de configuração. O `claude-accounts` se apoia exatamente nisso — sem binário modificado, sem malabarismo de credenciais:

- **Um perfil é só um diretório.** O registro é o próprio filesystem: `~/.claude-accounts/profiles/<nome>/` *é* o config dir, ou um arquivo `profiles/<nome>.path` cuja primeira linha aponta para um diretório customizado (`~` é expandido; um arquivo `.path` vence sobre um diretório de mesmo nome). Não há registro JSON para corromper, e o formato é idêntico em todos os sistemas.
- **O ambiente é setado só na invocação.** O wrapper resolve a conta e seta `CLAUDE_CONFIG_DIR` (mais `CLAUDE_ACCOUNT`, para que hooks que chamem `claude` de novo resolvam a *mesma* conta) apenas para aquele processo filho — no bash via prefixo de env por invocação, no PowerShell salvando e restaurando ao redor da chamada, e no cmd via um shim que roda a mesma resolução do PowerShell. Nada vaza para o seu shell.
- **Um motor, três shells.** O PowerShell usa o módulo diretamente; o Git Bash carrega o `.sh` via `source`; o cmd.exe usa os shims `bin\claude.cmd` / `bin\claude-account.cmd`, que repassam o argv ao módulo PowerShell (argv e exit codes preservados). Há um único motor de resolução por sistema, não um por shell.
- **Terminais são independentes.** Como nada é global, um terminal pode rodar `work` enquanto outro roda `personal`, simultaneamente, cada um com seu próprio histórico e suas sessões.
- **Contrato do wrapper.** Exit codes são preservados, stdin e a interatividade do TTY ficam intactos, e o argv depois do primeiro argumento posicional é repassado byte a byte.

## Notas por plataforma

### Windows

O `install.ps1` configura os três shells do Windows; rode `claude-account doctor` para ver quais estão configurados. Requer Windows PowerShell 5.1+ (PowerShell 7 também funciona).

- **PowerShell** — o módulo define as funções `claude` / `claude-account` diretamente.
  - Em scripts, cheque `$LASTEXITCODE`, e **não** `$?` — uma função wrapper não consegue propagar o `$?` de um executável nativo no PowerShell 5.1. O `$LASTEXITCODE` é preservado corretamente.
  - Um `--` sem aspas é consumido pelo próprio PowerShell antes de chegar ao wrapper. Coloque entre aspas quando precisar repassá-lo: `claude mcp add x '--' cmd -a token`.
- **Prompt de Comando (`cmd.exe`)** — os shims `bin\claude.cmd` / `bin\claude-account.cmd` (no início do seu User PATH) repassam o argv ao módulo PowerShell. Há um pequeno custo de inicialização do PowerShell por chamada. O `claude-account use` tem tratamento especial para ainda fixar a conta na sessão atual do cmd.
- **Git Bash / MSYS** — o mesmo `claude-accounts.sh` é carregado via `source` no `~/.bashrc` e encontra o `claude.exe` nativo automaticamente.
- Processos criados fora desses shells (scripts npm, git hooks, `Start-Process`) ainda passam por fora do wrapper. Rode `claude-account use <nome>` antes: ele exporta `CLAUDE_CONFIG_DIR` na sessão, e os processos filhos herdam.

### macOS

- Versões recentes do Claude Code guardam as credenciais OAuth no Keychain **indexadas pelo config dir**, então os perfis ficam totalmente isolados.
- Se você estiver numa versão antiga em que a entrada do Keychain se comporta como singleton (logar num perfil derruba o outro), a alternativa é um token de longa duração por perfil: rode `claude setup-token` com cada perfil ativo.

### Linux

- As credenciais ficam num arquivo dentro do config dir (`.credentials.json`), então o isolamento funciona sem configuração extra.

## Limitações

Lista honesta — saiba o que está levando:

- **Perfis são independentes após a criação.** O `add` (e o `migrate`) copiam as ferramentas e preferências da conta default — skills, agents, commands, plugins, settings, e suas sessões/projetos/histórico — mas é um retrato no momento da cópia. Depois disso os perfis divergem de forma independente. O login OAuth e os servidores MCP pessoais ficam no `.claude.json`, que **não** é copiado de propósito (carrega identidade), então os servidores MCP precisam ser readicionados por perfil.
- **Um binário compartilhado.** Todos os perfis rodam a mesma instalação do Claude Code. O auto-update é serializado pelo lock global do próprio Claude Code, então sessões simultâneas não brigam entre si — mas uma atualização vale para todos os perfis de uma vez.
- **`use` é por sessão de shell.** É uma variável de ambiente; terminais novos voltam à ordem normal de resolução. Para um padrão durável, use `bind` (por diretório).
- **O wrapper roda no seu shell.** É uma função de shell (PowerShell / bash) ou um shim no PATH (cmd). Qualquer coisa que invoque o binário `claude` sem passar por um desses shells passa por fora dele (veja as notas de Windows acima — o mesmo contorno com `claude-account use` vale em todas as plataformas).

## Comparação com alternativas

| Ferramenta | Abordagem | Por que claude-accounts |
| --- | --- | --- |
| cloak | Wrapper de shell | Somente bash; sem suporte a Windows/PowerShell |
| CAAM / claude-swap | Troca arquivos em `~/.claude` globalmente | Troca global: todos os terminais mudam de uma vez, sem duas contas em paralelo |
| claude-profiles (npm) | Gerenciador de perfis de settings | **Não** troca contas — gerencia perfis de settings, não logins |

O `claude-accounts` é por invocação (contas em paralelo), por diretório (`.claude-account`) e funciona em Windows (PowerShell, cmd e Git Bash), macOS e Linux com os mesmos comandos.

## Desinstalação

macOS / Linux:

```bash
# remova a linha 'source ~/.claude-accounts/claude-accounts.sh' do ~/.bashrc / ~/.zshrc
rm -rf ~/.claude-accounts
```

Windows (PowerShell):

```powershell
# 1. remova o bloco '# >>> claude-accounts >>>' do seu profile do PowerShell
notepad $PROFILE.CurrentUserAllHosts
# 2. remova o mesmo bloco do Git Bash, se existir: %USERPROFILE%\.bashrc
# 3. remova o shim dir do seu User PATH (a entrada que termina em \.claude-accounts\bin)
# 4. apague a instalação
Remove-Item -Recurse -Force ~\.claude-accounts
```

Apagar `~/.claude-accounts` apaga os logins, históricos e sessões dos perfis nomeados. Seu `~/.claude` original (o perfil `default`) nunca é tocado.

## Contribuindo

Veja [CONTRIBUTING.md](../CONTRIBUTING.md). As duas regras de ouro: toda mudança de comportamento entra nas **duas** implementações (e nas duas suítes de teste — Pester 5 e bats), e os testes nunca tocam o binário `claude` real (isolam com `CLAUDE_ACCOUNTS_HOME` / `CLAUDE_ACCOUNTS_DEFAULT_DIR` e um executável mock no `PATH`).

## Licença

[MIT](../LICENSE).
