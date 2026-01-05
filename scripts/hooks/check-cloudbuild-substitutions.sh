#!/usr/bin/env bash
# =============================================================================
# Cloud Build Substitutions Validator (Otimizado)
# =============================================================================
# Versão High-Performance usando AWK para análise léxica e validação.
#
# Valida:
#   - Built-ins ($PROJECT_ID, etc.)
#   - Customizadas ($_VAR declaradas)
#   - Shell escapes ($$VAR)
#   - Contexto (Script block vs YAML keys)
#
# =============================================================================
set -euo pipefail

# --- Configuração ---

# Built-ins permitidas
readonly ALLOWED_BUILTINS="PROJECT_ID BUILD_ID PROJECT_NUMBER SHORT_SHA COMMIT_SHA BRANCH_NAME TAG_NAME REF_NAME REPO_NAME REPO_FULL_NAME REVISION_ID LOCATION TRIGGER_NAME TRIGGER_BUILD_CONFIG_PATH SERVICE_ACCOUNT_EMAIL SERVICE_ACCOUNT"

# Variáveis de ambiente comuns de shell para ignorar dentro de blocos de script
readonly SHELL_VARS="HOME USER PATH PWD SHELL TERM LANG TMPDIR TMP TEMP HOSTNAME LOGNAME MAIL EDITOR VISUAL PAGER DISPLAY OLDPWD SHLVL IFS PS1 PS2 RANDOM SECONDS LINENO BASH BASH_VERSION BASH_VERSINFO PIPESTATUS FUNCNAME GITHUB_TOKEN"

# Cores
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

# =============================================================================
# Main Logic (AWK)
# =============================================================================

validate_files() {
    awk -v builtins_str="$ALLOWED_BUILTINS" \
        -v shell_vars_str="$SHELL_VARS" \
        -v red="$RED" \
        -v green="$GREEN" \
        -v yellow="$YELLOW" \
        -v nc="$NC" '

    BEGIN {
        # Inicializa mapas de lookup O(1)
        split(builtins_str, b, " "); for (i in b) builtins[b[i]]=1
        split(shell_vars_str, s, " "); for (i in s) shell_vars[s[i]]=1

        errors = 0
        warnings = 0
    }

    # Função para processar o arquivo que acabou de ser lido
    function validate_file(filename, lines, count,    i, line, raw_line, indent, in_script, script_indent, clean_line, n, vars, v, var_name, declared) {

        # Passo 1: Extrair substitutions declaradas
        # Procura linhas como: "  _VAR_NAME:"
        for (i = 1; i <= count; i++) {
            if (match(lines[i], /^[[:space:]]*(_[A-Z][A-Z0-9_]*)[[:space:]]*:/, arr)) {
                # Extrai o nome da variável capturado pelo grupo do regex
                # AWK standard não tem array de grupos no match facilmente acessível sem gawk
                # Então usamos split/substr logic para ser portável
                line = lines[i]
                sub(/^[[:space:]]*/, "", line)
                sub(/[[:space:]]*:.*/, "", line)
                declared[line] = 1
            }
        }

        # Passo 2: Validar linha a linha
        in_script = 0
        script_indent = 0

        for (i = 1; i <= count; i++) {
            raw_line = lines[i]

            # Ignora comentários
            if (raw_line ~ /^[[:space:]]*#/) continue

            # Calcula indentação atual (número de espaços no início)
            match(raw_line, /^[[:space:]]*/)
            indent = RLENGTH

            # Máquina de estado: Entrar/Sair de bloco de script
            # Detecta início: "- |" ou "- >" ou "script: |"
            if (raw_line ~ /-[[:space:]]*(\| |>)/ || raw_line ~ /:[[:space:]]*(\| |>)/) {
                in_script = 1
                script_indent = indent
                continue
            }

            if (in_script) {
                # Se linha vazia, mantém estado
                if (raw_line ~ /^[[:space:]]*$/) continue

                # Se a indentação for menor ou igual à do início do bloco E começou novo item ou chave
                if (indent <= script_indent && (raw_line ~ /^[[:space:]]*-/ || raw_line ~ /^[[:space:]]*[a-zA-Z0-9_]+:/)) {
                    in_script = 0
                }
            }

            # Limpeza da linha para análise
            clean_line = raw_line

            # Remove strings entre aspas simples (literal strings)
            gsub(/\047[^\047]*\047/, "", clean_line) # \047 é single quote

            # Remove variáveis escapadas corretamente ($$VAR) substituindo por espaço seguro
            gsub(/\$\$[A-Za-z_][A-Za-z0-9_]*/, " ", clean_line)

            # Procura por $VAR ou ${VAR}
            # O loop abaixo encontra todas as ocorrências na linha
            while (match(clean_line, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
                var_match = substr(clean_line, RSTART, RLENGTH)

                # Remove o match da linha para encontrar o próximo na próxima iteração
                clean_line = substr(clean_line, RSTART + RLENGTH)

                # Limpa ${} e $ para pegar só o nome
                var_name = var_match
                gsub(/^(\$\{?|\$)/, "", var_name)
                gsub(/\}?$/, "", var_name)

                # Análise da variável
                is_error = 0
                error_msg = ""

                # 1. É built-in?
                if (var_name in builtins) continue

                # 2. É substitution customizada (começa com _)?
                if (substr(var_name, 1, 1) == "_") {
                    if (!(var_name in declared)) {
                        print red "[ERROR]" nc " " filename ":" i
                        print "  Variável: " var_match
                        print "  Problema: Substitution não declarada no bloco substitutions"
                        print ""
                        errors++
                    }
                    continue
                }

                # 3. Variável sem prefixo _ (Shell var ou erro)
                if (in_script) {
                    # Dentro de script, variáveis comuns (PATH, ECHO, etc) ou lowercase são aceitas
                    # Verifica allowlist
                    if (var_name in shell_vars) continue

                    # Verifica locale (LC_)
                    if (index(var_name, "LC_") == 1) continue

                    # Verifica lowercase (convenção shell local)
                    if (var_name ~ /^[a-z]/) continue

                    # Se chegou aqui, é provável erro: deveria ser $$VAR ou $_VAR
                    print red "[ERROR]" nc " " filename ":" i
                    print "  Variável: " var_match
                    print "  Problema: Variável shell sem escape. Use $$" var_name " (Cloud Build substitui $VAR antes do shell)"
                    print ""
                    errors++
                } else {
                    # Fora de script, $VAR sem _ é inválido se não for builtin
                    print red "[ERROR]" nc " " filename ":" i
                    print "  Variável: " var_match
                    print "  Problema: Variável desconhecida. Use $_" var_name " (se for substitution) ou verifique built-ins"
                    print ""
                    errors++
                }
            }
        }
    }

    # --- Bloco de Controle de Arquivos ---

    # Ao ler primeira linha de um novo arquivo (exceto o primeiro absoluto se FNR==1)
    FNR == 1 {
        if (current_file != "") {
            validate_file(current_file, file_lines, line_count)
        }
        # Reset para novo arquivo
        current_file = FILENAME
        line_count = 0
        delete file_lines
    }

    {
        # Acumula linhas na memória
        line_count++
        file_lines[line_count] = $0
    }

    END {
        # Processa o último arquivo
        if (current_file != "") {
            validate_file(current_file, file_lines, line_count)
        }

        if (errors > 0 || warnings > 0) {
            print "===================================="
            printf "Resultado: %s%d erro(s)%s, %s%d aviso(s)%s\n", red, errors, nc, yellow, warnings, nc
        }

        if (errors > 0) exit 1
        else {
             print green "[OK]" nc " Validação concluída sem erros"
             exit 0
        }
    }
    ' "$@"
}

# =============================================================================
# Main
# =============================================================================

# Determina arquivos a analisar
FILES=()
if [[ $# -gt 0 ]]; then
    FILES=("$@")
else
    # Fallback para arquivos staged se nenhum argumento for passado
    while IFS= read -r f; do
        [[ -f "$f" ]] && FILES+=("$f")
    done < <(git diff --cached --name-only 2>/dev/null | grep -E 'cloudbuild.*\.ya?ml$' || true)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    exit 0
fi

echo "Cloud Build Substitutions Validator (Fast)"
echo "=========================================="

validate_files "${FILES[@]}"
