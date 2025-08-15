# Plugin: geminiChat
# Descrição: Plugin para OpenKore que usa Gemini AI para responder mensagens do jogo
# Autor: Lok1zer0
# Versão: 1.6

package geminiChat;

use strict;
use warnings;

# Forçar carregamento dos módulos do Strawberry Perl
BEGIN {
    # Adicionar caminhos do Strawberry Perl
    unshift @INC, 'C:/strawberry/perl/site/lib';
    unshift @INC, 'C:/strawberry/perl/vendor/lib';
    unshift @INC, 'C:/strawberry/perl/lib';
    
    # Se estiver em Program Files
    unshift @INC, 'C:/Program Files/strawberry/perl/site/lib';
    unshift @INC, 'C:/Program Files/strawberry/perl/vendor/lib';
    unshift @INC, 'C:/Program Files/strawberry/perl/lib';
}

use Plugins;
use Globals;
use Log qw(message warning error debug);
use Utils;
use I18N qw(stringToBytes);

# Verificar se módulos opcionais estão disponíveis
my $has_json = eval { 
    require JSON; 
    # Não importar nada, vamos usar de forma mais compatível
    1; 
};
my $has_lwp = eval { require LWP::UserAgent; 1; };
my $has_http = eval { require HTTP::Request::Common; HTTP::Request::Common->import(); 1; };

# DEBUG: Adicionar após as verificações
message "[geminiChat] DEBUG - Perl version: $]\n", "system";
message "[geminiChat] DEBUG - JSON: " . ($has_json ? "OK" : "FALTANDO") . "\n", "system";
message "[geminiChat] DEBUG - LWP: " . ($has_lwp ? "OK" : "FALTANDO") . "\n", "system";
message "[geminiChat] DEBUG - HTTP: " . ($has_http ? "OK" : "FALTANDO") . "\n", "system";

# Se ainda não funcionar, mostre os erros
if (!$has_json) {
    message "[geminiChat] Erro JSON: " . $@ . "\n", "system";
}
if (!$has_lwp) {
    message "[geminiChat] Erro LWP: " . $@ . "\n", "system";
}
if (!$has_http) {
    message "[geminiChat] Erro HTTP: " . $@ . "\n", "system";
}

# Variáveis do plugin - ADICIONAR ESTAS LINHAS
my $hooks;
my $ua;
my $gemini_api_key = "INSERT_YOUR_GEMINI_API_KEY_HERE"; # Substitua pela sua chave API
my $gemini_api_url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent";
my $plugin_name = "geminiChat";
my $enabled = 1;
my $response_delay = 5;
my %last_response_time;
my %last_message;
my %pending_responses;
my %processed_messages;
my %player_locks;
my %message_processing;
my %response_history;
my %absolute_lock;
my %execution_lock; # ADICIONAR - Bloqueio de execução para evitar re-fluxo

# NOVAS VARIÁVEIS PARA SISTEMA DE SEGUIR
my $follow_mode = 0;
my $follow_player = "";
my $follow_start_time = 0;
my $follow_duration = 120; # 2 minutos em segundos
my $follow_target_x = 0;
my $follow_target_y = 0;
my $original_ai_mode = "";

# Configurações
my $max_response_length = 100;
my $response_probability = 100;
my @ignore_players = ();

Plugins::register($plugin_name, "Plugin que usa Gemini AI para responder mensagens", \&onUnload);

sub onReload {
    onUnload();
}

sub onUnload {
    message "[geminiChat] Plugin descarregado.\n", "system";
    Plugins::delHooks($hooks) if $hooks;
    undef $hooks;
    undef $ua;
}

# Função para remover acentos - VERSÃO MELHORADA
sub removeAccents {
    my ($text) = @_;
    
    # Mapeamento de caracteres acentuados para sem acento
    my %accent_map = (
        'á' => 'a', 'à' => 'a', 'ã' => 'a', 'â' => 'a', 'ä' => 'a',
        'é' => 'e', 'è' => 'e', 'ê' => 'e', 'ë' => 'e',
        'í' => 'i', 'ì' => 'i', 'î' => 'i', 'ï' => 'i',
        'ó' => 'o', 'ò' => 'o', 'õ' => 'o', 'ô' => 'o', 'ö' => 'o',
        'ú' => 'u', 'ù' => 'u', 'û' => 'u', 'ü' => 'u',
        'ç' => 'c', 'ñ' => 'n',
        'Á' => 'a', 'À' => 'a', 'Ã' => 'a', 'Â' => 'a', 'Ä' => 'a',
        'É' => 'e', 'È' => 'e', 'Ê' => 'e', 'Ë' => 'e',
        'Í' => 'i', 'Ì' => 'i', 'Î' => 'i', 'Ï' => 'i',
        'Ó' => 'o', 'Ò' => 'o', 'Õ' => 'o', 'Ô' => 'o', 'Ö' => 'o',
        'Ú' => 'u', 'Ù' => 'u', 'Û' => 'u', 'Ü' => 'u',
        'Ç' => 'c', 'Ñ' => 'n'
    );
    
    # Substituir caracteres acentuados
    foreach my $accented (keys %accent_map) {
        $text =~ s/\Q$accented\E/$accent_map{$accented}/g;
    }
    
    return $text;
}

# Carregar configurações
sub loadConfig {
    $gemini_api_key = $config{gemini_api_key} || "";
    $enabled = $config{gemini_enabled} || 1;
    $response_delay = $config{gemini_delay} || 5; # Padrão 5 segundos
    $max_response_length = $config{gemini_max_length} || 150;
    $response_probability = $config{gemini_probability} || 80;
    
    if ($config{gemini_ignore_players}) {
        @ignore_players = split(/,/, $config{gemini_ignore_players});
    }
}

# Hook para mensagens públicas - VERSÃO CORRIGIDA PARA CAPTURA CORRETA DO JOGADOR
sub onPublicChat {
    my (undef, $args) = @_;
    return unless checkRequirements();
    
    # Debug inicial
    message "[geminiChat] DEBUG - Hook público chamado\n", "system";
    message "[geminiChat] DEBUG - Args completos: " . join(", ", map { "$_ => '$args->{$_}'" } keys %$args) . "\n", "system";
    
    # Tentar diferentes formas de capturar os dados
    my $message = "";
    my $player = "";
    my $player_x = 0;
    my $player_y = 0;
    
    # MÉTODO PRIORITÁRIO: Campos diretos mais comuns
    $message = $args->{Msg} || $args->{message} || $args->{privMsg} || "";
    $player = $args->{MsgUser} || $args->{user} || $args->{name} || $args->{nick} || $args->{privMsgUser} || "";
    
    # DEBUG: Mostrar dados capturados inicialmente
    message "[geminiChat] DEBUG - Captura inicial: player='$player', message='$message'\n", "system";
    
    # MÉTODO ALTERNATIVO 1: Se a mensagem contém formato "Nome: texto"
    if ($message && !$player && $message =~ /^([^:]+):\s*(.+)$/) {
        $player = $1;
        $message = $2;
        message "[geminiChat] DEBUG - Extraído do formato 'Nome: msg': player='$player', msg='$message'\n", "system";
    }
    
    # MÉTODO ALTERNATIVO 2: Verificar se algum campo contém o padrão completo
    if (!$player || !$message) {
        foreach my $key (keys %$args) {
            next unless defined $args->{$key};
            my $value = $args->{$key};
            
            # Procurar padrão "Nome : mensagem" ou "Nome: mensagem"
            if ($value =~ /^([^:]+)\s*:\s*(.+)$/) {
                my $potential_player = $1;
                my $potential_message = $2;
                
                # Limpar espaços
                $potential_player =~ s/^\s+|\s+$//g;
                $potential_message =~ s/^\s+|\s+$//g;
                
                # Verificar se não é o próprio bot
                if ($potential_player ne $char->{name} && length($potential_player) > 0) {
                    $player = $potential_player;
                    $message = $potential_message;
                    message "[geminiChat] DEBUG - Parseado de '$key': player='$player', msg='$message'\n", "system";
                    last;
                }
            }
        }
    }
    
    # Tentar obter coordenadas do jogador identificado
    if ($player && $playersList) {
        my $player_obj = $playersList->getByName($player);
        if ($player_obj) {
            $player_x = $player_obj->{pos_to}{x} || $player_obj->{pos}{x} || 0;
            $player_y = $player_obj->{pos_to}{y} || $player_obj->{pos}{y} || 0;
            message "[geminiChat] DEBUG - Coordenadas de '$player': ($player_x, $player_y)\n", "system";
        }
    }
    
    # Se ainda não conseguiu coordenadas, tentar dos args
    if (!$player_x || !$player_y) {
        $player_x = $args->{x} || $args->{X} || 0;
        $player_y = $args->{y} || $args->{Y} || 0;
    }
    
    # Limpar espaços e normalizar
    $player =~ s/^\s+|\s+$//g if $player;
    $message =~ s/^\s+|\s+$//g if $message;
    
    # VERIFICAÇÃO CRÍTICA: Garantir que não é o próprio bot
    if ($player eq $char->{name}) {
        message "[geminiChat] DEBUG - IGNORANDO: É o próprio bot ($player)\n", "system";
        return;
    }
    
    # Debug dos dados finais
    message "[geminiChat] DEBUG - Dados FINAIS: player='$player', message='$message', pos=($player_x, $player_y)\n", "system";
    
    # VERIFICAR PALAVRA-CHAVE "ENTENDEREI" ANTES DE OUTRAS VERIFICAÇÕES
    if ($message && $message =~ /\bentenderei\b/i) {
        if ($player && $player ne $char->{name}) {
            message "[geminiChat] PALAVRA-CHAVE DETECTADA: 'entenderei' de $player\n", "system";
            activateFollowMode($player, $player_x, $player_y);
            # NÃO RETORNAR - Deixar processar como mensagem normal para gerar resposta via Gemini
        } else {
            message "[geminiChat] DEBUG - PALAVRA-CHAVE detectada mas jogador inválido: '$player'\n", "system";
            return;
        }
    }
    
    # Verificar se conseguiu capturar os dados essenciais
    if (!$player || !$message) {
        message "[geminiChat] DEBUG - Dados incompletos: player='$player', message='$message'\n", "system";
        return;
    }
    
    # Verificar se o jogador não é vazio ou inválido
    if (length($player) < 2) {
        message "[geminiChat] DEBUG - Nome de jogador muito curto: '$player'\n", "system";
        return;
    }
    
    # Ignorar mensagens muito curtas
    if (length($message) < 3) {
        message "[geminiChat] DEBUG - Mensagem muito curta: " . length($message) . " caracteres\n", "system";
        return;
    }
    
    my $now = time();
    
    # VERIFICAÇÃO IMEDIATA: Bloqueio absoluto (5 segundos)
    if ($absolute_lock{$player}) {
        my $time_diff = $now - $absolute_lock{$player};
        if ($time_diff < 5) {
            message "[geminiChat] DEBUG - Hook Público: BLOQUEIO 5s ativo para $player\n", "system";
            return;
        }
    }
    
    # VERIFICAÇÃO IMEDIATA: Cooldown (5 segundos)
    if ($last_response_time{$player}) {
        my $time_diff = $now - $last_response_time{$player};
        if ($time_diff < 5) {
            message "[geminiChat] DEBUG - Hook Público: COOLDOWN 5s ativo para $player\n", "system";
            return;
        }
    }
    
    # Verificar processamento em andamento
    my $message_id = $player . "_" . $message . "_public_" . int($now/5); # 5 segundos de janela
    if ($message_processing{$message_id}) {
        message "[geminiChat] DEBUG - Hook Público: Mensagem já em processamento para $player\n", "system";
        return;
    }
    
    $message_processing{$message_id} = $now;
    
    message "[geminiChat] DEBUG - Hook Público: Verificando se deve responder para $player: '$message'\n", "system";
    
    unless (shouldRespond($player, $message, 'public')) {
        message "[geminiChat] DEBUG - shouldRespond retornou falso\n", "system";
        return;
    }
    
    scheduleResponse($player, $message, 'public');
}

# Hook para mensagens privadas - VERSÃO COM COOLDOWN DE 5 SEGUNDOS
sub onPrivateMessage {
    my (undef, $args) = @_;
    return unless checkRequirements();
    
    my $message = $args->{privMsg} || $args->{Msg} || $args->{message} || "";
    my $player = $args->{privMsgUser} || $args->{MsgUser} || $args->{user} || "";
    
    # Se não conseguiu capturar pelo args, tentar pelo próprio texto
    if (!$player || !$message) {
        if ($args->{messageList} && ref($args->{messageList}) eq 'ARRAY') {
            foreach my $msg (@{$args->{messageList}}) {
                if ($msg =~ /^\[De:\s*([^\]]+)\]\s*:\s*(.+)$/) {
                    $player = $1;
                    $message = $2;
                    last;
                }
            }
        }
    }
    
    return unless $player && $message;
    
    # Limpar espaços e normalizar
    $player =~ s/^\s+|\s+$//g;
    $message =~ s/^\s+|\s+$//g;
    
    # Ignorar mensagens muito curtas
    return if length($message) < 3;
    
    my $now = time();
    
    # VERIFICAÇÃO IMEDIATA: Bloqueio absoluto (5 segundos)
    if ($absolute_lock{$player}) {
        my $time_diff = $now - $absolute_lock{$player};
        if ($time_diff < 5) {
            message "[geminiChat] DEBUG - Hook: BLOQUEIO 5s ativo para $player\n", "system";
            return;
        }
    }
    
    # VERIFICAÇÃO IMEDIATA: Cooldown (5 segundos)
    if ($last_response_time{$player}) {
        my $time_diff = $now - $last_response_time{$player};
        if ($time_diff < 5) {
            message "[geminiChat] DEBUG - Hook: COOLDOWN 5s ativo para $player\n", "system";
            return;
        }
    }
    
    # Verificar processamento em andamento
    my $message_id = $player . "_" . $message . "_private_" . int($now/5); # 5 segundos de janela
    if ($message_processing{$message_id}) {
        message "[geminiChat] DEBUG - Hook: Mensagem ja em processamento para $player\n", "system";
        return;
    }
    
    $message_processing{$message_id} = $now;
    
    return unless shouldRespond($player, $message, 'private');
    
    scheduleResponse($player, $message, 'private');
}

# Verificar se deve responder - VERSÃO COM DEBUG MELHORADO PARA PÚBLICO
sub shouldRespond {
    my ($player, $message, $type) = @_;
    
    message "[geminiChat] DEBUG - shouldRespond chamado: $player ($type): '$message'\n", "system";
    
    unless ($enabled) {
        message "[geminiChat] DEBUG - Plugin desabilitado\n", "system";
        return 0;
    }
    
    if (grep { lc($_) eq lc($player) } @ignore_players) {
        message "[geminiChat] DEBUG - Jogador na lista de ignorados\n", "system";
        return 0;
    }
    
    my $now = time();
    
    # VERIFICAÇÃO 1: Bloqueio absoluto (MÁXIMO 5 SEGUNDOS)
    if ($absolute_lock{$player}) {
        my $time_diff = $now - $absolute_lock{$player};
        if ($time_diff < 5) { # Apenas 5 segundos
            message "[geminiChat] DEBUG - BLOQUEIO ABSOLUTO ativo para $player (${time_diff}s)\n", "system";
            return 0;
        } else {
            # Expirou, limpar
            delete $absolute_lock{$player};
            message "[geminiChat] DEBUG - Bloqueio absoluto expirado para $player\n", "system";
        }
    }
    
    # VERIFICAÇÃO 2: Último tempo de resposta (5 segundos)
    if ($last_response_time{$player}) {
        my $time_diff = $now - $last_response_time{$player};
        if ($time_diff < 5) { # 5 segundos após resposta
            message "[geminiChat] DEBUG - COOLDOWN ativo para $player (${time_diff}s)\n", "system";
            return 0;
        }
    }
    
    # VERIFICAÇÃO 3: Verificar se não há execução em andamento
    foreach my $exec_id (keys %execution_lock) {
        if ($exec_id =~ /^\Q$player\E_/) {
            message "[geminiChat] DEBUG - EXECUÇÃO em andamento para $player\n", "system";
            return 0;
        }
    }
    
    # VERIFICAÇÃO 4: Duplicata (reduzido para 300 segundos = 5 minutos)
    my $message_id = lc($player) . "_" . lc($message) . "_" . $type;
    if ($response_history{$message_id} && ($now - $response_history{$message_id}) < 300) {
        message "[geminiChat] DEBUG - DUPLICATA DETECTADA de $player\n", "system";
        return 0;
    }
    
    # VERIFICAÇÃO 5: Pendências
    foreach my $id (keys %pending_responses) {
        my $response_data = $pending_responses{$id};
        if ($response_data->{player} eq $player) {
            message "[geminiChat] DEBUG - PENDÊNCIA existente para $player\n", "system";
            return 0;
        }
    }
    
    # Lógica específica para chat público
    if ($type eq 'public') {
        my $char_name = $char->{name} || "";
        
        # Verificar se o nome do personagem foi mencionado
        if ($char_name && $message =~ /\Q$char_name\E/i) {
            message "[geminiChat] DEBUG - Chat público: Nome '$char_name' mencionado, respondendo\n", "system";
            # ATIVAR BLOQUEIOS ANTES DE RETORNAR TRUE
            $absolute_lock{$player} = $now;
            $response_history{$message_id} = $now;
            $player_locks{$player} = $now;
            $processed_messages{$player . "_" . $message . "_" . $type} = $now;
            $last_response_time{$player} = $now;
            return 1;
        }
        
        # Verificar probabilidade aleatória
        my $random_chance = rand(100);
        message "[geminiChat] DEBUG - Chat público: Chance aleatória $random_chance (limite: $response_probability)\n", "system";
        
        if ($random_chance < $response_probability) {
            message "[geminiChat] DEBUG - Chat público: Probabilidade aceita, respondendo\n", "system";
            # ATIVAR BLOQUEIOS ANTES DE RETORNAR TRUE
            $absolute_lock{$player} = $now;
            $response_history{$message_id} = $now;
            $player_locks{$player} = $now;
            $processed_messages{$player . "_" . $message . "_" . $type} = $now;
            $last_response_time{$player} = $now;
            return 1;
        } else {
            message "[geminiChat] DEBUG - Chat público: Probabilidade rejeitada\n", "system";
            return 0;
        }
    }
    
    # Para mensagens privadas, sempre responder (se passou pelas verificações)
    # ATIVAR BLOQUEIOS
    $absolute_lock{$player} = $now;
    $response_history{$message_id} = $now;
    $player_locks{$player} = $now;
    $processed_messages{$player . "_" . $message . "_" . $type} = $now;
    $last_response_time{$player} = $now;
    
    message "[geminiChat] DEBUG - ACEITANDO mensagem de $player (bloqueio 5s): $message\n", "system";
    
    return 1;
}

# Agendar resposta - VERSÃO SIMPLIFICADA
sub scheduleResponse {
    my ($player, $message, $type) = @_;

    # Se não está bloqueado, não deveria ter chegado aqui
    unless ($player_locks{$player}) {
        return;
    }

    my $delay = $response_delay;
    my $response_id = $player . "_" . time() . "_" . rand(1000);

    $pending_responses{$response_id} = {
        player => $player,
        message => $message,
        type => $type,
        time => time() + $delay
    };
    
    message "[geminiChat] DEBUG - Resposta agendada para $player em ${delay}s\n", "system";
}

# Processar respostas pendentes - VERSÃO COM LIMPEZA SUPER RÁPIDA
sub processResponses {
    my $now = time();
    
    # VERIFICAR E PROCESSAR MODO DE SEGUIR
    checkFollowMode();
    
    # Limpar bloqueios de execução antigos (mais de 10 segundos)
    foreach my $exec_id (keys %execution_lock) {
        if (($now - $execution_lock{$exec_id}) > 10) {
            delete $execution_lock{$exec_id};
        }
    }
    
    # Limpar bloqueios absolutos antigos (mais de 5 segundos)
    foreach my $player (keys %absolute_lock) {
        my $lock_time = $absolute_lock{$player};
        if (($now - $lock_time) > 5) {
            delete $absolute_lock{$player};
            message "[geminiChat] DEBUG - Bloqueio absoluto expirado para $player\n", "system";
        }
    }
    
    # Limpar outros bloqueios antigos
    foreach my $player (keys %player_locks) {
        if (($now - $player_locks{$player}) > 10) {
            delete $player_locks{$player};
        }
    }
    
    # Limpar controles de processamento antigos
    foreach my $hash (keys %message_processing) {
        if (($now - $message_processing{$hash}) > 10) {
            delete $message_processing{$hash};
        }
    }
    
    # Limpar cache de mensagens antigas
    foreach my $hash (keys %processed_messages) {
        if (($now - $processed_messages{$hash}) > 30) { # 30 segundos
            delete $processed_messages{$hash};
        }
    }
    
    # Limpar histórico de respostas antigas
    foreach my $id (keys %response_history) {
        if (($now - $response_history{$id}) > 300) { # 5 minutos
            delete $response_history{$id};
        }
    }
    
    foreach my $id (keys %pending_responses) {
        my $response_data = $pending_responses{$id};
        
        if ($now >= $response_data->{time}) {
            processMessage($response_data->{player}, $response_data->{message}, $response_data->{type});
            delete $pending_responses{$id};
        }
    }
}

# Processar mensagem - VERSÃO COM TIMEOUTS DE 5 SEGUNDOS
sub processMessage {
    my ($player, $message, $type) = @_;
    
    my $now = time();
    
    # VERIFICAÇÃO 1: Bloqueio de execução
    my $execution_id = $player . "_" . $now;
    if ($execution_lock{$execution_id}) {
        message "[geminiChat] DEBUG - Execução já em andamento para $player\n", "system";
        return;
    }
    $execution_lock{$execution_id} = $now;
    
    # VERIFICAÇÃO 2: Bloqueio absoluto
    unless ($absolute_lock{$player}) {
        message "[geminiChat] DEBUG - Processamento sem bloqueio absoluto para $player\n", "system";
        delete $execution_lock{$execution_id};
        return;
    }
    
    # VERIFICAÇÃO 3: Timeout de processamento (5 segundos)
    if (($now - $absolute_lock{$player}) > 5) {
        message "[geminiChat] DEBUG - Processamento expirado para $player\n", "system";
        delete $absolute_lock{$player};
        delete $player_locks{$player};
        delete $execution_lock{$execution_id};
        return;
    }
    
    message "[geminiChat] DEBUG - INICIANDO processamento para $player\n", "system";
    
    my $response = callGeminiAPI($player, $message, $type);
    
    if ($response) {
        # VERIFICAÇÃO FINAL TRIPLA
        $response = processResponseText($response, $player);
        $response = lc($response); # Forçar minúsculas novamente
        $response = removeAccents($response); # Remover acentos novamente
        
        # Verificação final se ainda tem o nome do jogador
        my $player_clean = lc(removeAccents($player));
        if ($response =~ /\b\Q$player_clean\E\b/i) {
            message "[geminiChat] DEBUG - AINDA CONTÉM NOME! Usando resposta padrão\n", "system";
            my @safe_responses = ("eae", "blz", "opa", "massa", "show");
            $response = $safe_responses[rand @safe_responses];
        }
        
        sendResponse($player, $response, $type);
        message "[geminiChat] DEBUG - RESPOSTA ENVIADA para $player: $response\n", "system";
        
        # COOLDOWN APÓS RESPONDER (5 segundos)
        $last_response_time{$player} = $now + 5;
        
    } else {
        message "[geminiChat] DEBUG - Falha ao gerar resposta para $player\n", "system";
    }
    
    # LIMPAR CONTROLES DE PROCESSAMENTO
    delete $player_locks{$player};
    delete $execution_lock{$execution_id};
    # NÃO deletar $absolute_lock aqui - ele expira automaticamente em 5s
    
    message "[geminiChat] DEBUG - PROCESSAMENTO FINALIZADO para $player\n", "system";
}

# Chamar API do Gemini - VERSÃO ULTRA ESPECÍFICA
sub callGeminiAPI {
    my ($player, $message, $type) = @_;
    
    # Verificar se tem todas as dependências necessárias
    unless ($has_json && $has_lwp && $has_http) {
        warning "[geminiChat] API nao disponivel: Modulos Perl necessarios nao encontrados\n";
        return undef;
    }
    
    # Verificar se tem API key
    unless ($gemini_api_key) {
        warning "[geminiChat] API nao disponivel: Chave API nao configurada no config.txt\n";
        return undef;
    }
    
    unless ($ua) {
        $ua = LWP::UserAgent->new(
            timeout => 10,
            agent => 'OpenKore-GeminiChat/1.6'
        );
    }
    
    my $char_name = $char->{name} || "aventureiro";
    my $char_class = $jobs_lut{$char->{jobID}} || "novato";
    
    # Prompt ULTRA específico
    my $prompt = "seu nick e $char_name, um $char_class em ragnarok online. " .
                "responda de forma casual brasileira. " .
                "REGRAS OBRIGATORIAS: " .
                "1. use APENAS letras minusculas " .
                "2. NAO use acentos ou cedilhas " .
                "3. NUNCA mencione nomes de jogadores " .
                "4. responda sem dirigir-se diretamente a ninguem " .
                "5. maximo 50 caracteres " .
                "6. seja natural e amigavel " .
                "mensagem recebida: \"$message\". " .
                "resposta em minusculas sem acentos:";
    
    # Criar estrutura de dados primeiro
    my $data = {
        contents => [{
            parts => [{
                text => $prompt
            }]
        }],
        generationConfig => {
            maxOutputTokens => 30, # Reduzido para forçar respostas menores
            temperature => 0.8,
            topP => 0.7,
        }
    };
    
    my $json_data;
    eval {
        $json_data = createJSON($data);
    };
    
    if ($@) {
        warning "[geminiChat] Erro ao criar JSON: $@\n";
        return undef;
    }
    
    # Debug: mostrar JSON criado
    message "[geminiChat] DEBUG - JSON enviado: " . substr($json_data, 0, 100) . "...\n", "system";
    
    my $request;
    eval {
        $request = HTTP::Request->new('POST', "$gemini_api_url?key=$gemini_api_key");
        $request->header('Content-Type' => 'application/json');
        $request->content($json_data);
    };
    
    if ($@) {
        warning "[geminiChat] Erro ao criar requisicao HTTP: $@\n";
        return undef;
    }
    
    my $response = $ua->request($request);
    
    # Debug: mostrar status da resposta
    message "[geminiChat] DEBUG - Status HTTP: " . $response->status_line . "\n", "system";
    
    if ($response->is_success) {
        # Debug: mostrar parte da resposta
        my $content_preview = substr($response->content, 0, 200);
        message "[geminiChat] DEBUG - Resposta OK: $content_preview...\n", "system";
        
        my $result;
        eval {
            $result = parseJSON($response->content);
        };
        
        if ($@) {
            warning "[geminiChat] Erro ao decodificar resposta: $@\n";
            return undef;
        }
        
        if ($result && $result->{candidates} && @{$result->{candidates}}) {
            my $text = $result->{candidates}[0]{content}{parts}[0]{text};
            
            # Debug: mostrar texto extraído
            message "[geminiChat] DEBUG - Texto extraido bruto: '$text'\n", "system";
            
            # PROCESSAMENTO PARA FORÇAR MINÚSCULAS E LIMPAR
            $text = processResponseText($text, $player);
            
            message "[geminiChat] DEBUG - Texto final processado: '$text'\n", "system";
            
            return $text;
        } else {
            warning "[geminiChat] Resposta vazia da Gemini API\n";
            return undef;
        }
    } else {
        # Mostrar erro detalhado
        warning "[geminiChat] Erro HTTP: " . $response->status_line . "\n";
        warning "[geminiChat] Conteudo do erro: " . $response->content . "\n";
        
        if ($response->code == 404) {
            warning "[geminiChat] URL usada: $gemini_api_url?key=" . substr($gemini_api_key, 0, 10) . "...\n";
        }
        
        return undef;
    }
}

# Enviar resposta - VERSÃO MELHORADA
sub sendResponse {
    my ($player, $response, $type) = @_;
    
    message "[geminiChat] DEBUG - Enviando resposta ($type) para $player: '$response'\n", "system";
    
    if ($type eq 'private') {
        # Múltiplas tentativas de envio de MP
        my $success = 0;
        
        # Método 1: pm direto
        eval {
            Commands::run("pm \"$player\" $response");
            $success = 1;
        };
        
        # Método 2: se falhou, tentar com sintaxe alternativa
        unless ($success) {
            eval {
                Commands::run("pm $player $response");
                $success = 1;
            };
        }
        
        # Método 3: usar sendMessage se disponível
        unless ($success) {
            eval {
                sendMessage("pm", $response, $player);
                $success = 1;
            };
        }
        
        if ($success) {
            message "[geminiChat] MP para $player: $response\n", "pm";
        } else {
            warning "[geminiChat] Falha ao enviar MP para $player\n";
        }
        
    } else {
        # Chat público
        eval {
            Commands::run("c $response");
            message "[geminiChat] Chat público: $response\n", "selfchat";
        };
        
        if ($@) {
            warning "[geminiChat] Erro ao enviar mensagem pública: $@\n";
        }
    }
}

# Verificar requisitos
sub checkRequirements {
    return $enabled;
}

# Inicialização do plugin
message "[geminiChat] Plugin carregado v1.6 - Automatico | Delay: 5s | Sem acentos.\n", "success";

loadConfig();

# Registrar hooks - VERSÃO COM HOOKS ALTERNATIVOS
$hooks = Plugins::addHooks(
    ['packet/public_chat', \&onPublicChat],
    ['packet_pre/public_chat', \&onPublicChat],  # Hook alternativo
    ['ChatQueue::add', \&onPublicChat],          # Hook de chat queue
    ['packet/private_message', \&onPrivateMessage],
    ['configModify', \&loadConfig],
    ['mainLoop_pre', \&processResponses]
);

# Verificar dependências na inicialização
unless ($has_json) {
    warning "[geminiChat] Modulo JSON nao encontrado. API nao disponivel.\n";
}
unless ($has_lwp) {
    warning "[geminiChat] Modulo LWP::UserAgent nao encontrado. API nao disponivel.\n";
}
unless ($has_http) {
    warning "[geminiChat] Modulo HTTP::Request::Common nao encontrado. API nao disponivel.\n";
}

# Função para criar JSON manualmente (compatível com versões antigas)
sub createJSON {
    my ($data) = @_;
    
    my $prompt = $data->{contents}[0]{parts}[0]{text};
    
    # Escapar caracteres especiais
    $prompt =~ s/\\/\\\\/g;  # Escapar barras invertidas
    $prompt =~ s/"/\\"/g;    # Escapar aspas
    $prompt =~ s/\n/\\n/g;   # Escapar quebras de linha
    $prompt =~ s/\r/\\r/g;   # Escapar retorno de carro
    $prompt =~ s/\t/\\t/g;   # Escapar tabs
    
    my $json = '{' .
        '"contents":[{' .
            '"parts":[{' .
                '"text":"' . $prompt . '"' .
            '}]' .
        '}],' .
        '"generationConfig":{' .
            '"maxOutputTokens":40,' .
            '"temperature":0.9,' .
            '"topP":0.8' .
        '}' .
    '}';
    
    return $json;
}

# Função para decodificar JSON simples - VERSÃO COM PROCESSAMENTO IMEDIATO
sub parseJSON {
    my ($json_text) = @_;
    
    # Debug: mostrar parte da resposta
    my $debug_text = substr($json_text, 0, 300);
    message "[geminiChat] DEBUG - Resposta recebida: $debug_text...\n", "system";
    
    # Primeiro, tentar encontrar o padrão específico do Gemini
    if ($json_text =~ /"text"\s*:\s*"([^"]*)"/) {
        my $text = $1;
        
        # Limpar caracteres de escape
        $text =~ s/\\n/ /g;
        $text =~ s/\\r//g;
        $text =~ s/\\t/ /g;
        $text =~ s/\\"/"/g;
        $text =~ s/\\\\/\\/g;
        
        # FORÇAR MINÚSCULAS IMEDIATAMENTE
        $text = lc($text);
        
        # Remover acentos
        $text = removeAccents($text);
        
        # Remover espaços extras
        $text =~ s/^\s+|\s+$//g;
        $text =~ s/\s+/ /g;
        
        message "[geminiChat] DEBUG - Texto extraido e limpo: '$text'\n", "system";
        
        if ($text && length($text) > 0) {
            return { 
                candidates => [{ 
                    content => { 
                        parts => [{ 
                            text => $text 
                        }] 
                    } 
                }] 
            };
        }
    }
    
    # Padrão alternativo
    if ($json_text =~ /"text"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/) {
        my $text = $1;
        
        # Decodificar caracteres escapados
        $text =~ s/\\n/ /g;
        $text =~ s/\\r//g;
        $text =~ s/\\t/ /g;
        $text =~ s/\\"/"/g;
        $text =~ s/\\\\/\\/g;
        
        # FORÇAR MINÚSCULAS IMEDIATAMENTE
        $text = lc($text);
        
        # Remover acentos
        $text = removeAccents($text);
        
        # Remover espaços extras
        $text =~ s/^\s+|\s+$//g;
        $text =~ s/\s+/ /g;
        
        message "[geminiChat] DEBUG - Texto extraido (pattern 2): '$text'\n", "system";
        
        if ($text && length($text) > 0) {
            return { 
                candidates => [{ 
                    content => { 
                        parts => [{ 
                            text => $text 
                        }] 
                    } 
                }] 
            };
        }
    }
    
    message "[geminiChat] DEBUG - Nenhum texto foi extraido da resposta\n", "system";
    return undef;
}

# Processar texto da resposta - VERSÃO ULTRA AGRESSIVA
sub processResponseText {
    my ($text, $player_name) = @_;
    
    message "[geminiChat] DEBUG - Texto antes do processamento: '$text'\n", "system";
    
    # Limpar quebras de linha e caracteres especiais
    $text =~ s/\n/ /g;
    $text =~ s/\r//g;
    $text =~ s/\t/ /g;
    $text =~ s/^\s+|\s+$//g;
    $text =~ s/\s+/ /g;
    
    # FORÇAR MINÚSCULAS PRIMEIRO
    $text = lc($text);
    
    # Remover acentos
    $text = removeAccents($text);
    
    # Remover QUALQUER variação do nome do jogador
    my $player_clean = lc($player_name);
    $player_clean = removeAccents($player_clean);
    
    message "[geminiChat] DEBUG - Nome do jogador limpo: '$player_clean'\n", "system";
    
    # Remover nome exato (case insensitive)
    $text =~ s/\b\Q$player_clean\E\b//gi;
    $text =~ s/\b\Q$player_name\E\b//gi;
    
    # Remover variações comuns
    $text =~ s/\b(oi|ola|ei|eae|hey|e ai)\s+\Q$player_clean\E\b/oi/gi;
    $text =~ s/\b\Q$player_clean\E\s+(oi|ola|ei|eae|hey|e ai)\b/oi/gi;
    
    # Remover saudações com nome
    $text =~ s/\beae\s+\Q$player_clean\E\b/eae/gi;
    $text =~ s/\be\s+ai\s+\Q$player_clean\E\b/e ai/gi;
    
    # Remover padrões específicos que apareceram no debug
    $text =~ s/\bblza?\s+\Q$player_clean\E\b/blz/gi;
    $text =~ s/\btudo\s+sussao?\s+\Q$player_clean\E\b/tudo sussao/gi;
    
    # Substituir padrões de resposta direta
    $text =~ s/\bpara\s+(voce|tu)\b//gi;
    $text =~ s/\bvoce\b/tu/gi;
    
    # Remover espaços duplos criados pelas substituições
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    
    # Limpar pontuações duplicadas
    $text =~ s/[.]{2,}/./g;
    $text =~ s/[!]{2,}/!/g;
    $text =~ s/[?]{2,}/?/g;
    
    # Garantir que não comece com pontuação
    $text =~ s/^[.,!?;\s]+//;
    
    message "[geminiChat] DEBUG - Texto após remoção de nomes: '$text'\n", "system";
    
    # Limitar tamanho
    if (length($text) > $max_response_length) {
        $text = substr($text, 0, $max_response_length - 3) . "...";
    }
    
    # Se ficou muito curto, vazio ou só pontuação, usar resposta padrão
    if (!$text || length($text) < 3 || $text =~ /^[.,!?\s]*$/) {
        my @default_responses = (
            "eae blz",
            "opa tudo certo", 
            "tranquilo",
            "massa",
            "show de bola",
            "beleza"
        );
        $text = $default_responses[rand @default_responses];
        message "[geminiChat] DEBUG - Usando resposta padrão: '$text'\n", "system";
    }
    
    message "[geminiChat] DEBUG - Texto final: '$text'\n", "system";
    
    return $text;
}

# NOVAS FUNÇÕES PARA SISTEMA DE SEGUIR

# Ativar modo de seguir - VERSÃO COM VERIFICAÇÃO EXTRA
sub activateFollowMode {
    my ($player, $x, $y) = @_;
    
    # VERIFICAÇÃO CRÍTICA: Garantir que não vai seguir a si mesmo
    if (!$player || $player eq $char->{name}) {
        message "[geminiChat] ERRO: Tentativa de seguir jogador inválido: '$player'\n", "error";
        return;
    }
    
    # Verificar se o jogador existe na lista
    my $player_exists = 0;
    if ($playersList) {
        my $player_obj = $playersList->getByName($player);
        if ($player_obj) {
            $player_exists = 1;
            # Atualizar coordenadas se não foram fornecidas
            if (!$x || !$y) {
                $x = $player_obj->{pos_to}{x} || $player_obj->{pos}{x} || 0;
                $y = $player_obj->{pos_to}{y} || $player_obj->{pos}{y} || 0;
            }
        }
    }
    
    if (!$player_exists) {
        message "[geminiChat] AVISO: Jogador '$player' não encontrado na lista, mas tentando seguir mesmo assim\n", "warning";
    }
    
    message "[geminiChat] *** ATIVANDO MODO SEGUIR ***\n", "system";
    message "[geminiChat] Alvo: $player\n", "system";
    message "[geminiChat] Coordenadas: ($x, $y)\n", "system";
    message "[geminiChat] Meu nome: " . $char->{name} . "\n", "system";
    
    # Salvar modo AI atual
    $original_ai_mode = AI::state() || "auto";
    
    # Configurar variáveis de seguir
    $follow_mode = 1;
    $follow_player = $player;
    $follow_start_time = time();
    $follow_target_x = $x;
    $follow_target_y = $y;
    
    # Mudar para modo manual
    Commands::run("ai manual");
    message "[geminiChat] AI alterada para MANUAL\n", "success";
    
    # Se temos coordenadas válidas, ir até elas
    if ($x > 0 && $y > 0) {
        message "[geminiChat] Movendo para coordenadas ($x, $y) do jogador $player\n", "system";
        Commands::run("move $x $y");
    } else {
        message "[geminiChat] Coordenadas inválidas, tentando localizar $player\n", "warning";
        findAndMoveToPlayer($player);
    }
}

# Desativar modo de seguir - VERSÃO CORRIGIDA PARA FORÇAR AI AUTO
sub deactivateFollowMode {
    message "[geminiChat] DESATIVANDO MODO SEGUIR - Voltando ao normal\n", "system";
    
    # Debug do estado atual da AI
    my $current_ai_state = AI::state() || "unknown";
    message "[geminiChat] Estado AI atual: $current_ai_state\n", "system";
    message "[geminiChat] AI original salva: $original_ai_mode\n", "system";
    
    # Resetar variáveis
    $follow_mode = 0;
    $follow_player = "";
    $follow_start_time = 0;
    $follow_target_x = 0;
    $follow_target_y = 0;
    
    # FORÇAR SEMPRE AI AUTO - MÉTODO MAIS DIRETO
    message "[geminiChat] Executando comando: ai auto\n", "system";
    Commands::run("ai auto");
    
    # Aguardar um pouco e verificar se funcionou
    my $timeout = 0;
    while (AI::state() ne "auto" && $timeout < 5) {
        sleep(1);
        $timeout++;
        my $new_state = AI::state() || "unknown";
        message "[geminiChat] Aguardando AI mudar... Estado atual: $new_state (tentativa $timeout)\n", "system";
        
        # Tentar novamente se não mudou
        if ($timeout < 5) {
            Commands::run("ai auto");
        }
    }
    
    # Verificação final
    my $final_state = AI::state() || "unknown";
    if ($final_state eq "auto") {
        message "[geminiChat] AI restaurada para AUTO com sucesso!\n", "success";
    } else {
        message "[geminiChat] AVISO: AI não retornou para AUTO. Estado atual: $final_state\n", "warning";
        
        # Tentativa final mais agressiva
        eval {
            Commands::run("ai clear");
            sleep(1);
            Commands::run("ai auto");
            message "[geminiChat] Tentativa de recuperação: ai clear + ai auto\n", "system";
        };
        
        # Verificar novamente
        my $recovery_state = AI::state() || "unknown";
        message "[geminiChat] Estado após recuperação: $recovery_state\n", "system";
    }
    
    # Limpar variável de modo original
    $original_ai_mode = "";
    
    message "[geminiChat] *** MODO SEGUIR DESATIVADO ***\n", "system";
}

# Verificar e processar modo de seguir - VERSÃO COM TIMEOUT MAIS PRECISO
sub checkFollowMode {
    return unless $follow_mode;
    
    my $now = time();
    my $elapsed = $now - $follow_start_time;
    
    # Verificar se passou do tempo limite (2 minutos = 120 segundos)
    if ($elapsed >= $follow_duration) {
        message "[geminiChat] *** TEMPO LIMITE ATINGIDO ***\n", "system";
        message "[geminiChat] Tempo decorrido: ${elapsed}s (limite: ${follow_duration}s)\n", "system";
        message "[geminiChat] Parando de seguir $follow_player\n", "system";
        deactivateFollowMode();
        return;
    }
    
    # Se ainda está no modo seguir, continuar atualizando posição
    if ($follow_player) {
        my $remaining = $follow_duration - $elapsed;
        
        # Atualizar posição a cada 5 segundos
        if ($elapsed % 5 == 0) {
            message "[geminiChat] *** SEGUINDO $follow_player ***\n", "info";
            message "[geminiChat] Tempo restante: ${remaining}s\n", "info";
            updatePlayerPosition($follow_player);
        }
        
        # Aviso quando restam 30 segundos
        if ($remaining <= 30 && $remaining > 25) {
            message "[geminiChat] AVISO: Restam apenas ${remaining}s de seguimento\n", "warning";
        }
        
        # Aviso quando restam 10 segundos
        if ($remaining <= 10 && $remaining > 5) {
            message "[geminiChat] AVISO: Seguimento terminando em ${remaining}s\n", "warning";
        }
    }
}

# Ativar modo de seguir - VERSÃO COM MELHOR DEBUG E SALVAMENTO
sub activateFollowMode {
    my ($player, $x, $y) = @_;
    
    # VERIFICAÇÃO CRÍTICA: Garantir que não vai seguir a si mesmo
    if (!$player || $player eq $char->{name}) {
        message "[geminiChat] ERRO: Tentativa de seguir jogador inválido: '$player'\n", "error";
        return;
    }
    
    # Verificar se o jogador existe na lista
    my $player_exists = 0;
    if ($playersList) {
        my $player_obj = $playersList->getByName($player);
        if ($player_obj) {
            $player_exists = 1;
            # Atualizar coordenadas se não foram fornecidas
            if (!$x || !$y) {
                $x = $player_obj->{pos_to}{x} || $player_obj->{pos}{x} || 0;
                $y = $player_obj->{pos_to}{y} || $player_obj->{pos}{y} || 0;
            }
        }
    }
    
    if (!$player_exists) {
        message "[geminiChat] AVISO: Jogador '$player' não encontrado na lista, mas tentando seguir mesmo assim\n", "warning";
    }
    
    message "[geminiChat] *** ATIVANDO MODO SEGUIR ***\n", "system";
    message "[geminiChat] Alvo: $player\n", "system";
    message "[geminiChat] Coordenadas: ($x, $y)\n", "system";
    message "[geminiChat] Meu nome: " . $char->{name} . "\n", "system";
    
    # Salvar modo AI atual ANTES de mudar
    $original_ai_mode = AI::state() || "auto";
    message "[geminiChat] Modo AI atual salvo: $original_ai_mode\n", "system";
    
    # Configurar variáveis de seguir
    $follow_mode = 1;
    $follow_player = $player;
    $follow_start_time = time();
    $follow_target_x = $x;
    $follow_target_y = $y;
    
    # Mudar para modo manual
    message "[geminiChat] Executando: ai manual\n", "system";
    Commands::run("ai manual");
    
    # Verificar se mudou
    my $new_ai_state = AI::state() || "unknown";
    message "[geminiChat] Estado AI após comando: $new_ai_state\n", "system";
    
    if ($new_ai_state eq "manual") {
        message "[geminiChat] AI alterada para MANUAL com sucesso!\n", "success";
    } else {
        message "[geminiChat] AVISO: AI pode não ter mudado corretamente\n", "warning";
    }
    
    # Se temos coordenadas válidas, ir até elas
    if ($x > 0 && $y > 0) {
        message "[geminiChat] Movendo para coordenadas ($x, $y) do jogador $player\n", "system";
        Commands::run("move $x $y");
    } else {
        message "[geminiChat] Coordenadas inválidas, tentando localizar $player\n", "warning";
        findAndMoveToPlayer($player);
    }
    
    message "[geminiChat] *** MODO SEGUIR ATIVO POR ${follow_duration}s ***\n", "success";
}

# Encontrar e mover para jogador
sub findAndMoveToPlayer {
    my ($player_name) = @_;
    
    return unless $playersList;
    
    my $player_obj = $playersList->getByName($player_name);
    if ($player_obj) {
        my $x = $player_obj->{pos_to}{x} || $player_obj->{pos}{x};
        my $y = $player_obj->{pos_to}{y} || $player_obj->{pos}{y};
        
        if ($x && $y) {
            message "[geminiChat] Jogador $player_name encontrado em ($x, $y)\n", "info";
            Commands::run("move $x $y");
            $follow_target_x = $x;
            $follow_target_y = $y;
        } else {
            message "[geminiChat] Não foi possível obter coordenadas de $player_name\n", "warning";
        }
    } else {
        message "[geminiChat] Jogador $player_name não encontrado na lista\n", "warning";
    }
}

# Atualizar posição do jogador
sub updatePlayerPosition {
    my ($player_name) = @_;
    
    return unless $playersList;
    
    my $player_obj = $playersList->getByName($player_name);
    if ($player_obj) {
        my $x = $player_obj->{pos_to}{x} || $player_obj->{pos}{x};
        my $y = $player_obj->{pos_to}{y} || $player_obj->{pos}{y};
        
        # Verificar se o jogador se moveu significativamente
        if ($x && $y) {
            my $distance = int(sqrt(($x - $follow_target_x)**2 + ($y - $follow_target_y)**2));
            
            if ($distance > 3) { # Se moveu mais de 3 células
                message "[geminiChat] $player_name se moveu para ($x, $y) - distância: $distance\n", "info";
                Commands::run("move $x $y");
                $follow_target_x = $x;
                $follow_target_y = $y;
            }
        }
    }
}

# Agendar resposta de confirmação para o modo seguir
sub scheduleFollowResponse {
    my ($player) = @_;
    
    my $response_id = $player . "_follow_" . time() . "_" . rand(1000);
    
    $pending_responses{$response_id} = {
        player => $player,
        message => "ok, vou te seguir por 2 minutos",
        type => 'public',
        time => time() + 2 # Responder em 2 segundos
    };
    
    message "[geminiChat] Resposta de seguir agendada para $player\n", "system";
}

return 1;