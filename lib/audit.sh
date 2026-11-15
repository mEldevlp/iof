#!/usr/bin/env bash

# Аудит безопасности: iof audit run | show | cron, для панели iof api audit.
# Блоки: server («Аудит сервера») и dpi («Защита от РКН»: насколько узел заметен для фильтров
# и зондов). Узлы отдают факты (n_audit_server, n_audit_dpi), оценку каждой проверки ставят
# audit_eval_server и audit_eval_dpi здесь: так консоль, Telegram и панель видят одно и то же.
# Блок dpi ещё смотрит на узел снаружи, с управляющего сервера (audit_outside). Результат лежит
# в $AUDIT_DIR/<блок>.json, история запусков в history.jsonl, оба файла ведёт python3 (AUDIT_PY).
# Узлы аудит не меняет, поэтому во время переноса управления он разрешён, как check

# Справочник проверок для панели и iof audit show, строки через TAB:
#  B блок заголовок;  G блок группа заголовок;  K id блок группа название «почему это важно»
audit_catalog() {
  local b="server"
  g() { printf 'G\t%s\t%s\t%s\n' "$b" "$1" "$2"; }
  k() { printf 'K\t%s\t%s\t%s\t%s\t%s\n' "$1" "$b" "$2" "$3" "$4"; }
  printf 'B\tserver\tАудит сервера\n'
  g ssh "SSH"
  g net "Сеть и защита от подбора"
  g upd "Обновления"
  g sys "Система"
  k ssh_root ssh "Вход root по SSH" \
    "Имя root известно заранее, поэтому пароль подбирают в первую очередь к нему. Вход только по ключу подбором не взять. iof заходит на узлы по ключу, пароль root ему не нужен."
  k ssh_password ssh "Вход по паролю" \
    "Пароль можно подобрать или подсмотреть, ключ нельзя. Боты перебирают пароли SSH на любом сервере круглые сутки."
  k ssh_port ssh "Порт SSH" \
    "На порт 22 приходит основной поток автоматического подбора. При входе только по ключу это шум в журнале, при входе по паролю — риск."
  k ssh_keys ssh "Вход по ключу" \
    "По ключу iof выполняет команды на узле. Если authorized_keys доступен на запись другим пользователям, в него можно дописать чужой ключ."
  k firewall net "Файрвол" \
    "Без запрета по умолчанию снаружи доступно всё, что слушает порт, в том числе службы, поставленные случайно. Файрвол хостера (security group) с узла не виден: если он есть, это предупреждение можно оставить."
  k ban net "Блокировка подбора" \
    "fail2ban или CrowdSec блокируют адрес после нескольких неудачных входов. При входе по паролю это основная защита от подбора, при входе только по ключу — чистый журнал."
  k ban_port net "Порт sshd в fail2ban" \
    "Если jail sshd следит не за тем портом, на котором слушает SSH, блокировка адреса не закрывает ему SSH."
  k auth_fail net "Неудачные входы за сутки" \
    "Много попыток значит, что сервер перебирают. При входе только по ключу они безвредны."
  k ports net "Слушающие порты" \
    "Каждый открытый порт — это служба, которую можно атаковать и по которой узел можно опознать. Ожидаемые: SSH, Hysteria2, контейнер AmneziaWG, порты ретранслятора. То, что слушает только 127.0.0.1, снаружи недоступно."
  k updates upd "Ожидающие обновления" \
    "Обновления безопасности закрывают известные уязвимости. iof-nightly ставит их каждую ночь, если он запланирован в cron."
  k reboot upd "Перезагрузка" \
    "Новое ядро и системные библиотеки начинают работать только после перезагрузки. iof-nightly перезагружает узел после обновления."
  k nightly upd "Ночное обслуживание" \
    "iof-nightly обновляет пакеты и перезагружает узел. Если он давно не отрабатывал, узел остаётся без обновлений."
  k sudo_log sys "Журнал sudo" \
    "По журналу sudo видно, кто и какие команды выполнял от root. Без него не разобраться, что происходило на сервере."
  k pwquality sys "Требования к паролям" \
    "pam_pwquality не даёт задать короткий или простой пароль. Важно там, где по паролю входят в SSH или вызывают sudo."
  k suid sys "SUID-файлы" \
    "SUID-файл выполняется с правами владельца, обычно root. Лишний такой файл — способ повысить права, его же оставляют после взлома."

  # Блок dpi. Тексты не обещают, что узел не найдут: проверка показывает, чем он заметен
  b="dpi"
  printf 'B\tdpi\tЗащита от РКН (ТСПУ)\n'
  g hy2 "Hysteria2"
  g awg "AmneziaWG"
  g probe "Что видно снаружи"
  g scan "Сканеры"
  g rep "Репутация адреса"
  g hyg "Гигиена"
  k hy2_mode hy2 "Режим маскировки" \
    "Без маскировки Hysteria2 — это QUIC, который на запрос по HTTP/3 отвечает ошибкой 404: такой сервер легко отличить от сайта. Salamander делает трафик похожим на случайный шум, но на QUIC он уже не похож. Без Salamander с masquerade сервер выглядит как сайт с HTTP/3, но QUIC к зарубежным адресам фильтры режут. Это выбор, а не ошибка."
  k hy2_masq hy2 "Masquerade" \
    "Тому, кто пришёл на порт Hysteria2 без пароля, сервер показывает сайт из masquerade. Если цель не отвечает, зонд увидит ошибку вместо сайта. Под Salamander masquerade снаружи не виден."
  k hy2_quic hy2 "Ответ на зонд QUIC" \
    "Управляющий сервер отправляет на порт Hysteria2 пакет QUIC с несуществующей версией. Обычный сервер QUIC отвечает согласованием версий, под Salamander порт так не отвечает. Так видно, что получит тот, кто зондирует порт, и доходит ли до узла UDP."
  k hy2_port hy2 "Порт" \
    "HTTP/3 работает на 443/udp, QUIC на другом порту встречается редко и заметнее. Под Salamander трафик не похож на QUIC на любом порту."
  k hy2_hop hy2 "Смена портов (port hopping)" \
    "Клиент раз в полминуты меняет порт, поэтому блокировка одного порта или долгого потока UDP не обрывает связь. Для этого нужен диапазон портов на сервере и он же в ссылке клиента. iof включает диапазон на узле (iof hy2 hop), а список портов попадает только в ссылки групп с --hop: старые клиенты такую ссылку не импортируют."
  k hy2_template hy2 "Конфиг и шаблон" \
    "iof hy2 install ставит на узлы конфиг по шаблону с управляющего сервера. Если конфиг узла потом правили вручную, маскировка на нём отличается от остальных, а повторная установка затрёт правки."
  k awg_params awg "Параметры обфускации" \
    "AmneziaWG отличается от WireGuard мусорными пакетами (Jc, Jmin, Jmax), добавками к пакетам (S1–S4) и своими заголовками (H1–H4). С нулями и заголовками 1, 2, 3, 4 это обычный WireGuard, который фильтры узнают по первому пакету."
  k awg_same awg "Одинаковые параметры на узлах" \
    "С одинаковыми параметрами трафик узлов выглядит одинаково: признак, найденный для одного узла, подойдёт ко всем. Сравнение идёт по хэшу, сами значения в панель и в файлы не попадают."
  k tcp_web probe "Порты 80 и 443/tcp" \
    "Сайт с HTTP/3 отвечает и по обычному HTTPS на 443/tcp. Если на 443/udp есть QUIC, а 443/tcp закрыт, сервер на сайт не похож. Посторонняя служба на этих портах показывает зонду свои заголовки и сертификат."
  k tls_cert probe "Сертификат" \
    "Сертификат видит любой, кто подключится к порту. Самоподписанный сертификат на имя известного сайта на адресе, который этому сайту не принадлежит, — заметный признак."
  k icmp probe "Ответ на ping" \
    "Обычный сервер чаще отвечает на ping. Молчание само ничего не выдаёт: так настроено у многих хостеров."
  k names probe "Имя сервера и PTR" \
    "Обратную запись DNS (PTR) видит любой по адресу узла, имя сервера попадает в приветствия служб. Слова vpn, proxy, wg в них говорят о назначении сервера."
  k banners probe "Лишние порты снаружи" \
    "Служба на лишнем порту отвечает приветствием с названием и версией программы. По нему сканер понимает, что стоит на сервере."
  k panel probe "Панель iof-web" \
    "Панель управляет всеми узлами от root. Она должна слушать только 127.0.0.1 и открываться через SSH-туннель: на внешнем адресе её найдёт любой сканер."
  k blocklist scan "Блок-лист сканеров" \
    "Список адресов, с которых узлы сканируют и зондируют. Если пакеты от них отбрасывать, сканер с этих адресов видит закрытый сервер. Это снижает заметность, но не прячет узел: сканеры меняют адреса. Применяет и обновляет список iof block."
  k asn rep "Сеть и хостер" \
    "Сети крупных хостеров VPS фильтры знают и относятся к ним строже, чем к домашним. Это справка: изменить её можно только переездом к другому хостеру."
  k registry rep "Адрес в реестре" \
    "Если адрес узла есть в выгрузке реестра блокировок, у части провайдеров он уже недоступен и клиенты до него не дойдут."
  k journald hyg "Срок хранения журнала" \
    "В журнале остаются адреса клиентов и время подключений. Если сервер изымут или взломают, журнал покажет, кто им пользовался. Чем короче срок хранения, тем меньше можно узнать."
  k hy2_log hyg "Журнал Hysteria2" \
    "На уровне info Hysteria2 пишет в журнал адрес каждого подключившегося клиента, на debug ещё и адреса, куда он ходит."
  k awg_log hyg "Лог контейнера AmneziaWG" \
    "Docker по умолчанию пишет вывод контейнера в файл без ограничения размера. Со временем он занимает диск и хранит историю дольше, чем нужно."
  k time hyg "Время" \
    "При сбитых часах не проходит проверка сертификатов, а время в журналах узлов не сходится между собой."
  unset -f g k
}

# Ответ n_audit_* в A, повторяющиеся ключи в массивы A_*
declare -A A=()
A_LISTEN=(); A_EXPECT=(); A_RELAY=(); A_SUID=(); A_BLOCK=(); A_AWGP=(); A_AWGI=(); A_BANNER=()

audit_parse() {
  local line k v
  A=(); A_LISTEN=(); A_EXPECT=(); A_RELAY=(); A_SUID=(); A_BLOCK=(); A_AWGP=(); A_AWGI=(); A_BANNER=()
  while IFS= read -r line; do
    [[ "$line" == ?*=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    v="${v//$'\t'/ }"
    case "$k" in
      listen)    A_LISTEN+=("$v") ;;
      expect)    A_EXPECT+=("$v") ;;
      relay)     A_RELAY+=("$v") ;;
      suid)      A_SUID+=("$v") ;;
      hy2_block) A_BLOCK+=("$v") ;;
      awg_p)     A_AWGP+=("$v") ;;
      awg_i)     A_AWGI+=("$v") ;;
      x_banner)  A_BANNER+=("$v") ;;
      *)         A["$k"]="$v" ;;
    esac
  done <<<"$1"
}

# Слушающие порты узла по фактам в A_LISTEN, A_EXPECT и A_RELAY, аргументы — порты SSH узла.
# AP_EXP — ожидаемые, AP_EXTRA — лишние (их номера в AP_XP), AP_LOC — слушают только loopback,
# AP_REL — правила ретранслятора (их порты в AP_GOT), AP_OPEN — что должен пропускать файрвол, кроме SSH
AP_EXP=(); AP_EXTRA=(); AP_XP=(); AP_LOC=(); AP_REL=(); AP_GOT=(); AP_OPEN=()
audit_ports() {
  local l e proto port bind proc found
  AP_EXP=(); AP_EXTRA=(); AP_XP=(); AP_LOC=(); AP_REL=(); AP_GOT=(); AP_OPEN=()
  for l in "${A_LISTEN[@]}"; do
    IFS='|' read -r proto port bind proc <<<"$l"
    if [[ "$bind" == "loopback" ]]; then AP_LOC+=("$port/$proto ${proc:-?}"); continue; fi
    if [[ "$proc" == "sshd" || ( "$proto" == "tcp" && " $* " == *" $port "* ) ]]; then AP_EXP+=("$port/$proto SSH"); continue; fi
    if [[ "$proc" == "hysteria" ]]; then AP_EXP+=("$port/$proto Hysteria2"); AP_OPEN+=("$port/$proto"); continue; fi
    found=""
    for e in "${A_EXPECT[@]}"; do
      if [[ "$e" == "$proto|$port|"* ]]; then found="${e##*|}"; break; fi
    done
    if [[ -n "$found" ]]; then AP_EXP+=("$port/$proto $found"); continue; fi
    if [[ "$proto" == "udp" && ( "$port" == "68" || "$port" == "546" ) ]]; then AP_EXP+=("$port/udp DHCP-клиент"); continue; fi
    AP_EXTRA+=("$port/$proto ${proc:-?}")
    AP_XP+=("$port")
  done
  for e in "${A_EXPECT[@]}"; do
    IFS='|' read -r proto port found <<<"$e"
    AP_OPEN+=("$port/$proto")
  done
  for l in "${A_RELAY[@]}"; do
    IFS='|' read -r proto port found <<<"$l"
    AP_REL+=("$port/$proto → $found")
    AP_GOT+=("$port")
    AP_OPEN+=("$port/$proto")
  done
}

# Строка проверки для AUDIT_PY: id, статус (good, warn, crit, none), значение, подробности,
# как исправить (текст) и команды. В подробностях и командах строки разделяет \x1f
# Строка проверки для AUDIT_PY: id, оценка, значение, подробности, как исправить, команды и действия
# панели через пробел (hop_on, hop_off, hy2_upgrade, block_on, block_update, block_off): кнопки
# на странице «Безопасность», которыми iof сам меняет узел
audit_chk() { printf 'C\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}" "${7:-}"; }
audit_lines() { local IFS=$'\x1f'; printf '%s' "$*"; }
# Аргументы через ", "
audit_list() { local s; s="$(audit_lines "$@")"; printf '%s' "${s//$'\x1f'/, }"; }
# Число от узла: всё, что не число, становится нулём, ведущие нули не превращают его в восьмеричное
audit_num() { if [[ "${1:-}" =~ ^[0-9]{1,15}$ ]]; then printf '%s' "$((10#$1))"; else printf '0'; fi; }
audit_when() { date -d "@$1" '+%d.%m.%Y %H:%M' 2>/dev/null || printf '%s' "$1"; }

# Оценка блока «Аудит сервера» для узла с индексом $1 по фактам $2 (вывод n_audit_server).
# Команды в «как исправить» не должны отрезать iof: он заходит на узел по ключу, иногда не под root
audit_eval_server() {
  local i="$1" name="${N_NAME[$1]}" target="${N_SSH[$1]}" user="root" where="На узле от root:"
  local now pw=0 fwd=0 prl keys mode ports=() jp=() exp=() extra=() xp=() loc=() open=() rel=() got=() want=() d=() c=()
  local e p r found st val hint cmd n sec na jails
  local reload="sshd -t && systemctl reload ssh"
  audit_parse "$2"
  now="$(audit_num "${A[now]:-}")"
  if [[ "$target" == *@* ]]; then user="${target%%@*}"; fi
  if [[ "$target" == "local" ]]; then where="На этом сервере от root:"; fi
  val="${A[ssh_ports]:-}"
  # shellcheck disable=SC2086 # порты через запятую в слова
  for p in ${val//,/ }; do
    if port_ok "$p"; then ports+=("$p"); fi
  done
  if [[ "${A[ssh_passwordauthentication]:-}" == "yes" || "${A[ssh_kbdinteractiveauthentication]:-}" == "yes" ]]; then pw=1; fi
  if [[ "${A[fw_policy]:-}" == "deny" ]]; then fwd=1; fi
  prl="${A[ssh_permitrootlogin]:-}"
  keys="$(audit_num "${A[ssh_keys]:-}")"

  # SSH
  if [[ "${A[ssh_conf]:-}" != "yes" ]]; then
    for p in ssh_root ssh_password ssh_port; do
      audit_chk "$p" none "sshd -T не ответил, настройки SSH не прочитать"
    done
  else
    case "$prl" in
      yes)
        if (( pw )); then st="crit"; val="разрешён, в том числе по паролю"; else st="warn"; val="разрешён, пароли выключены"; fi
        if [[ "$target" == "local" ]]; then
          hint="Это управляющий сервер, iof работает на нём без SSH. Если сам заходишь под root, оставь ему вход только по ключу. $where"
          cmd="echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/00-iof-root.conf && $reload"
        elif [[ "$user" == "root" ]]; then
          hint="iof заходит на этот узел под root по ключу, поэтому совсем запрещать root нельзя: оставь ему вход только по ключу. $where"
          cmd="echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/00-iof-root.conf && $reload"
        else
          hint="iof заходит на этот узел под $user, root по SSH ему не нужен. $where"
          cmd="echo 'PermitRootLogin no' > /etc/ssh/sshd_config.d/00-iof-root.conf && $reload"
        fi
        audit_chk ssh_root "$st" "$val" "" "$hint" "$cmd" ;;
      no) audit_chk ssh_root good "запрещён" ;;
      "") audit_chk ssh_root none "нет данных" ;;
      *)  audit_chk ssh_root good "только по ключу ($prl)" ;;
    esac

    if (( ! pw )); then
      audit_chk ssh_password good "выключен"
    else
      val="включён"
      if [[ "${A[ssh_passwordauthentication]:-}" != "yes" ]]; then val="включён через keyboard-interactive"; fi
      if [[ "$prl" == "yes" ]]; then st="crit"; val+=", root тоже"; else st="warn"; val+=", root по паролю нельзя"; fi
      d=()
      if (( keys == 0 )); then
        d+=("В authorized_keys пользователя $user ключей нет: сначала добавь свой ключ, иначе потеряешь доступ к серверу")
      fi
      audit_chk ssh_password "$st" "$val" "$(audit_lines "${d[@]}")" \
        "Сначала убедись, что сам входишь на сервер по ключу: iof уже ходит по ключу, ему пароль не нужен. $where" \
        "printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/00-iof-password.conf && $reload"
    fi

    val="$(audit_list "${ports[@]}")"
    if (( pw )) && [[ " ${ports[*]} " == *" 22 "* ]]; then
      hint="Надёжнее выключить вход по паролю (проверка «Вход по паролю»): тогда порт не важен. Если пароли нужны, порт можно сменить, например на 2222: открой его в файрволе, затем выполни команду ниже."
      if [[ "$target" != "local" ]]; then
        split_target "$target"
        hint+=" После неё на управляющем сервере в /root/iof/nodes.conf поставь узлу $name адрес SSH $T_HOST:2222. $where"
      else
        hint+=" $where"
      fi
      audit_chk ssh_port warn "$val, вход по паролю включён" "" "$hint" \
        "echo 'Port 2222' > /etc/ssh/sshd_config.d/00-iof-port.conf && sshd -t && systemctl daemon-reload && { systemctl restart ssh.socket 2>/dev/null; systemctl restart ssh; }"
    elif (( pw )); then
      audit_chk ssh_port good "$val"
    else
      audit_chk ssh_port good "$val, вход только по ключу"
    fi
  fi

  mode="${A[ssh_keys_mode]:-600}"
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then mode=600; fi
  if [[ "${A[ssh_conf]:-}" == "yes" && "${A[ssh_pubkeyauthentication]:-yes}" != "yes" ]]; then
    audit_chk ssh_keys crit "выключен (PubkeyAuthentication no)" "" "$where" \
      "echo 'PubkeyAuthentication yes' > /etc/ssh/sshd_config.d/00-iof-pubkey.conf && $reload"
  elif (( keys == 0 )); then
    audit_chk ssh_keys warn "у $user нет ключей в authorized_keys" "" \
      "Добавь свой публичный ключ. Со своего компьютера:" "ssh-copy-id $user@${N_ADDR[$i]}"
  elif (( 8#$mode & 8#022 )); then
    audit_chk ssh_keys warn "ключей у $user: $keys, но authorized_keys доступен на запись не только владельцу (права $mode)" "" \
      "$where" "chmod 600 ~$user/.ssh/authorized_keys"
  else
    audit_chk ssh_keys good "включён, ключей у $user: $keys"
  fi

  # Слушающие порты: что ожидаемо, что лишнее, что слушает только loopback. open — порты,
  # которые должен пропускать файрвол, кроме SSH
  if (( ${#ports[@]} == 0 )); then
    ports=(22)
    if [[ "$target" != "local" ]]; then split_target "$target"; ports=("$T_PORT"); fi
  fi
  audit_ports "${ports[@]}"
  exp=("${AP_EXP[@]}"); extra=("${AP_EXTRA[@]}"); xp=("${AP_XP[@]}"); loc=("${AP_LOC[@]}")
  open=("${AP_OPEN[@]}"); rel=("${AP_REL[@]}"); got=("${AP_GOT[@]}")
  for r in "${!R_VIA[@]}"; do
    [[ "${R_VIA[$r]}" == "$name" ]] || continue
    for p in "${R_HYL[$r]}" "${R_AWL[$r]}"; do
      if [[ "$p" != "-" ]]; then want+=("$p"); fi
    done
  done

  # Файрвол. Команды сначала открывают то, что нужно iof и клиентам, и только потом включают запрет
  if [[ -z "${A[fw]:-}" ]]; then
    audit_chk firewall none "нет данных"
  elif (( fwd )); then
    audit_chk firewall good "${A[fw]}: входящие по умолчанию запрещены"
  else
    if [[ "${A[fw]}" == "none" ]]; then
      val="нет, снаружи доступно всё, что слушает порт"
    else
      val="${A[fw]}: правила есть, но входящие по умолчанию разрешены"
    fi
    if (( ${#extra[@]} > 0 )); then st="crit"; val+=", есть лишние порты"; else st="warn"; fi
    c=("apt-get install -y ufw")
    for p in "${ports[@]}"; do c+=("ufw allow $p/tcp"); done
    while IFS= read -r p; do
      if [[ -n "$p" ]]; then c+=("ufw allow $p"); fi
    done < <(printf '%s\n' "${open[@]}" | sort -u)
    c+=("ufw default deny incoming" "ufw --force enable")
    if (( ${#rel[@]} > 0 )); then c+=("systemctl restart iof-relay"); fi
    audit_chk firewall "$st" "$val" "" \
      "Команды сначала открывают порты SSH, Hysteria2, AmneziaWG и ретранслятора этого узла, потом включают запрет остального. Сверь список со своими службами. $where" \
      "$(audit_lines "${c[@]}")"
  fi

  # fail2ban или CrowdSec и порт jail sshd
  jails="${A[f2b_jails]:-}"
  if [[ "${A[f2b]:-}" == "active" ]]; then
    if [[ ",$jails," == *",sshd,"* ]]; then
      audit_chk ban good "fail2ban работает, jail: ${jails//,/, }"
      IFS=',' read -r -a jp <<<"${A[f2b_port]:-}"
      found=""
      for p in "${ports[@]}"; do
        st=""
        for e in "${jp[@]}"; do
          e="${e// /}"
          case "$e" in
            ssh)  e=22 ;;
            *:*)  if [[ "$e" =~ ^([0-9]+):([0-9]+)$ ]] && (( 10#$p >= 10#${BASH_REMATCH[1]} && 10#$p <= 10#${BASH_REMATCH[2]} )); then e="$p"; fi ;;
          esac
          if [[ "$e" == "$p" ]]; then st="ok"; fi
        done
        if [[ -z "$st" ]]; then found+="${found:+,}$p"; fi
      done
      if [[ -z "${A[f2b_port]:-}" ]]; then
        audit_chk ban_port none "порт jail sshd определить не удалось"
      elif [[ -z "$found" ]]; then
        audit_chk ban_port good "совпадает: ${A[f2b_port]}"
      else
        audit_chk ban_port warn "jail следит за ${A[f2b_port]}, а SSH слушает $(audit_list "${ports[@]}")" "" "$where" \
          "printf '[sshd]\nenabled = true\nport = $(audit_lines "${ports[@]}" | tr '\037' ',')\n' > /etc/fail2ban/jail.d/iof-sshd.local && systemctl restart fail2ban"
      fi
    else
      audit_chk ban warn "fail2ban работает, но jail sshd не включён" "" "$where" \
        "printf '[sshd]\nenabled = true\n' > /etc/fail2ban/jail.d/iof-sshd.local && systemctl restart fail2ban"
      audit_chk ban_port none "jail sshd не включён"
    fi
  elif [[ "${A[crowdsec]:-}" == "active" ]]; then
    audit_chk ban good "CrowdSec работает"
    audit_chk ban_port none "у CrowdSec порт не задаётся"
  elif [[ -z "${A[f2b]:-}" ]]; then
    audit_chk ban none "нет данных"
    audit_chk ban_port none "нет данных"
  else
    if (( pw )); then st="crit"; val="нет, а вход по паролю включён"; else st="warn"; val="нет, вход только по ключу"; fi
    audit_chk ban "$st" "$val" "" "В Ubuntu jail sshd включён сразу после установки. $where" \
      "apt-get install -y fail2ban && systemctl enable --now fail2ban"
    audit_chk ban_port none "fail2ban не работает"
  fi

  n="${A[auth_fail]:-}"
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    audit_chk auth_fail none "нет данных (нет journalctl)"
  elif (( ! pw )); then
    audit_chk auth_fail good "$n, вход только по ключу"
  elif (( n < 10 )); then
    audit_chk auth_fail good "$n"
  else
    if (( n > 50 )); then st="crit"; else st="warn"; fi
    audit_chk auth_fail "$st" "$n, вход по паролю включён" "" \
      "Выключи вход по паролю и поставь fail2ban: проверки «Вход по паролю» и «Блокировка подбора»."
  fi

  # Ожидаемые порты идут в подробности, когда значение занято лишними
  d=()
  e=""
  if (( ${#exp[@]} > 0 )); then e="Ожидаемые: $(audit_list "${exp[@]}")"; fi
  if (( ${#rel[@]} > 0 )); then d+=("Ретранслятор (DNAT, без сокета): $(audit_list "${rel[@]}")"); fi
  if (( ${#loc[@]} > 0 )); then d+=("Только локально (loopback): $(audit_list "${loc[@]}")"); fi
  if (( ${#extra[@]} > 0 )); then
    if (( fwd )); then st="warn"; val="лишние: $(audit_list "${extra[@]}") (файрвол закрывает их, если они не разрешены явно)"
    else st="crit"; val="лишние: $(audit_list "${extra[@]}"), файрвола нет"; fi
    audit_chk ports "$st" "$val" "$(audit_lines "$e" "${d[@]}")" \
      "Узнай, что это за служба. Если она не нужна, останови её, иначе закрой порт файрволом. $where" \
      "$(audit_lines "ss -tulnp | grep -E ':($(audit_lines "${xp[@]}" | tr '\037' '|')) '" "systemctl disable --now <служба>")"
  elif [[ "$(printf '%s\n' "${got[@]}" | sort -u)" != "$(printf '%s\n' "${want[@]}" | sort -u)" ]]; then
    audit_chk ports warn "правила ретранслятора на узле не совпадают с relays.conf" "$(audit_lines "$e" "${d[@]}")" \
      "На управляющем сервере:" "sudo iof relay apply"
  elif (( ${#A_LISTEN[@]} == 0 )); then
    audit_chk ports none "нет данных (нет ss)"
  else
    audit_chk ports good "только ожидаемые: $(audit_list "${exp[@]}")" "$(audit_lines "${d[@]}")"
  fi

  # Обновления, перезагрузка, ночное обслуживание
  na="$(audit_num "${A[nightly_at]:-}")"
  if [[ -z "${A[upd_total]:-}" ]]; then
    audit_chk updates none "нет данных (нет apt)"
  else
    n="$(audit_num "${A[upd_total]}")"
    sec="$(audit_num "${A[upd_security]:-}")"
    p="$(audit_num "${A[apt_updated]:-}")"
    d=()
    if (( p > 0 )); then d+=("Списки пакетов обновлялись $(audit_when "$p")"); fi
    if (( n == 0 && p > 0 && now - p > 7 * 86400 )); then
      audit_chk updates warn "неизвестно: списки пакетов не обновлялись больше недели" "$(audit_lines "${d[@]}")" "$where" \
        "apt-get update && apt-get -y upgrade"
    elif (( n == 0 )); then
      audit_chk updates good "нет" "$(audit_lines "${d[@]}")"
    else
      st="warn"
      val="$n, из них безопасности: $sec"
      if (( sec > 0 && now - na > 7 * 86400 )); then st="crit"; val+=", iof-nightly на узле не работал больше недели"; fi
      audit_chk updates "$st" "$val" "$(audit_lines "${d[@]}")" \
        "Чтобы обновления ставились сами каждую ночь, запланируй iof-nightly (проверка «Ночное обслуживание»). Поставить сейчас. $where" \
        "apt-get update && apt-get -y upgrade"
    fi
  fi

  case "${A[reboot]:-}" in
    yes) audit_chk reboot warn "нужна${A[reboot_pkgs]:+ (${A[reboot_pkgs]% })}" "" \
           "Клиенты узла отключатся на минуту. iof-nightly перезагружает узлы сам. $where" "reboot" ;;
    no)  audit_chk reboot good "не нужна" ;;
    *)   audit_chk reboot none "нет данных" ;;
  esac

  hint="На управляющем сервере: sudo crontab -e, строка ниже. Каждую ночь в 4:00 обновятся и перезагрузятся все узлы."
  cmd="0 4 * * * /usr/local/sbin/iof-nightly"
  if (( na == 0 )); then
    audit_chk nightly warn "на этом узле ещё не запускалось" "" "$hint" "$cmd"
  elif (( now - na > 48 * 3600 )); then
    audit_chk nightly warn "давно: последний раз $(audit_when "$na")" "" "$hint" "$cmd"
  elif (( $(audit_num "${A[nightly_err]:-}") > 0 )); then
    audit_chk nightly warn "отработало $(audit_when "$na"), ошибок apt: ${A[nightly_err]}" "" \
      "Что пошло не так, видно в логе. $where" "grep -n '^E: ' /var/log/iof-nightly.log | tail"
  else
    audit_chk nightly good "отработало $(audit_when "$na")"
  fi

  # Система: журнал sudo, требования к паролям, SUID-файлы
  case "${A[sudo_log]:-}" in
    syslog) if [[ "${A[authlog]:-}" == "yes" ]]; then audit_chk sudo_log good "в журнале systemd и /var/log/auth.log"
            else audit_chk sudo_log good "в журнале systemd"; fi ;;
    file)   audit_chk sudo_log good "в отдельном файле (logfile в sudoers)" ;;
    off)    audit_chk sudo_log crit "выключен (Defaults !syslog в sudoers)" "" \
              "Найди эту строку и убери её через visudo. $where" "grep -rn '!syslog' /etc/sudoers /etc/sudoers.d" ;;
    nosudo) audit_chk sudo_log none "sudo не установлен" ;;
    *)      audit_chk sudo_log none "нет данных" ;;
  esac

  n="$(audit_num "${A[pwq_minlen]:-}")"
  d=()
  if (( ! pw )); then d+=("Вход по паролю в SSH выключен: это касается только локальных паролей и sudo"); fi
  if [[ -z "${A[pwq_pam]:-}" ]]; then
    audit_chk pwquality none "нет данных"
  elif [[ "${A[pwq_pam]}" == "yes" ]] && (( n >= 12 )); then
    audit_chk pwquality good "pam_pwquality, минимальная длина $n"
  else
    if [[ "${A[pwq_pam]}" != "yes" ]]; then val="не настроено"
    elif (( n > 0 )); then val="pam_pwquality включён, минимальная длина $n"
    else val="pam_pwquality включён, минимальная длина по умолчанию (8)"; fi
    audit_chk pwquality warn "$val" "$(audit_lines "${d[@]}")" "$where" \
      "apt-get install -y libpam-pwquality && sed -i -E 's/^#? ?minlen.*/minlen = 12/' /etc/security/pwquality.conf"
  fi

  n="$(audit_num "${A[suid_total]:-}")"
  if (( ${#A_SUID[@]} > 0 )); then
    audit_chk suid warn "вне стандартного набора Ubuntu 24.04: ${#A_SUID[@]} из $n" "$(audit_lines "${A_SUID[@]}")" \
      "Узнай, из какого пакета файл. Если он не нужен, сними с него SUID. $where" \
      "$(audit_lines "dpkg -S ${A_SUID[*]:0:5}" "chmod u-s <путь>")"
  elif [[ "${A[suid_done]:-}" == "no" ]]; then
    audit_chk suid none "поиск не уложился в 45 секунд, найдено $n"
  elif [[ -z "${A[suid_total]:-}" ]]; then
    audit_chk suid none "нет данных"
  else
    audit_chk suid good "$n, все из стандартного набора Ubuntu 24.04"
  fi
}

# Блок «Защита от РКН» (dpi): чем узел заметен для фильтров и зондов. Узел отдаёт факты
# (n_audit_dpi), управляющий сервер смотрит на него снаружи (audit_outside) и ставит оценки
# (audit_eval_dpi). Соль запуска AUDIT_SALT живёт только в памяти: хэши с ней годятся для сравнения
# внутри одной проверки, в файлы не пишутся

AUDIT_RUN="server"   # блоки этого запуска через пробел
AUDIT_SALT=""
AUDIT_TPL_SRC=""     # шаблон Hysteria2 на управляющем сервере и хэши его блоков
AUDIT_TPL=""
declare -A AUDIT_AWG=()   # узел -> хэш параметров AmneziaWG в этом запуске

# Проверки снаружи и работа со списками, всё под timeout в вызывающем коде. Режимы:
#  quic <адрес> <порт>     пакет QUIC с несуществующей версией: vn — сервер ответил согласованием
#                          версий, reply — ответил чем-то другим, silent — молчит, closed — порт закрыт
#  banner <адрес> <порт>   open|приветствие службы, closed или filtered
#  whois <адрес> <папка кэша>   состояние|AS|организация|страна; состояние: ok, private, fail.
#                          Запрос идёт на whois.iana.org, оттуда к региональному реестру. Пустая
#                          папка — без кэша (так спрашивается адрес ПК при проверке с ПК)
#  inlist <файл> <адрес>   hit|запись, если адрес есть в списке IP и CIDR, иначе miss
#  trace <адрес> <порт> <отпечаток> <порт Hysteria2 или 0>   токен на stdin. Контроль проверки с ПК:
#                          те же слои до мишени, что проходит probe.ps1 на ПК, JSON в одну строку
AUDIT_NET_PY=$(cat <<'EOF'
import hashlib, ipaddress, json, os, re, socket, ssl, subprocess, sys, time


def quic(host, port):
    # Длинный заголовок, версия из зарезервированных под согласование (RFC 9000, 6.3), пакет
    # дополнен до 1200 байт: сервер QUIC обязан ответить Version Negotiation с версией 0
    # и нашими идентификаторами соединения, поменянными местами
    seen = "silent"
    for _ in range(3):
        dcid, scid = os.urandom(8), os.urandom(8)
        pkt = bytes([0xC0 | (os.urandom(1)[0] & 0x0F)]) + bytes.fromhex("1a2a3a4a") + b"\x08" + dcid + b"\x08" + scid
        pkt += os.urandom(1200 - len(pkt))
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        try:
            s.connect((host, port))
            s.send(pkt)
            data = s.recv(2048)
        except socket.timeout:
            continue
        except ConnectionRefusedError:
            seen = "closed"
            continue
        except OSError:
            continue
        finally:
            s.close()
        if len(data) >= 14 and data[0] & 0x80 and data[1:5] == b"\0\0\0\0" and data[5] == 8 and data[6:14] == scid:
            return "vn"
        seen = "reply"
    return seen


def banner(host, port):
    try:
        s = socket.create_connection((host, port), timeout=3)
    except socket.timeout:
        return "filtered"
    except OSError:
        return "closed"
    data = b""
    try:
        s.settimeout(2)
        try:
            data = s.recv(256)
        except socket.timeout:
            # Служба ждёт запроса первой: спросим как браузер
            s.sendall(b"HEAD / HTTP/1.0\r\n\r\n")
            s.settimeout(3)
            data = s.recv(1024)
    except OSError:
        pass
    finally:
        s.close()
    text = data.decode("latin-1")
    server = re.search(r"^Server:[ \t]*(.+)$", text, re.M | re.I)
    lines = text.strip().splitlines()
    line = "HTTP, Server: " + server.group(1) if server else lines[0] if lines else ""
    clean = "".join(ch if 32 <= ord(ch) < 127 and ch != "|" else "." for ch in line.strip())
    return "open|" + clean[:80]


def ask(server, query):
    with socket.create_connection((server, 43), timeout=8) as s:
        s.settimeout(8)
        s.sendall((query + "\r\n").encode())
        data = b""
        while len(data) < 300000:
            chunk = s.recv(8192)
            if not chunk:
                break
            data += chunk
    # LACNIC и часть старых записей отвечают в latin-1
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")


def field(text, names):
    for name in names:
        m = re.search(r"^%s:[ \t]*(\S.*)$" % name, text, re.M | re.I)
        if m:
            return m.group(1).strip()
    return ""


def whois(ip, cache):
    if not ipaddress.ip_address(ip).is_global:
        return "private|||"
    path = os.path.join(cache, "whois-%s.txt" % ip) if cache else ""
    try:
        if path and time.time() - os.path.getmtime(path) < 86400:
            with open(path, encoding="utf-8") as f:
                return f.read().strip()
    except OSError:
        pass
    try:
        refer = field(ask("whois.iana.org", ip), ["refer", "whois"])
        if not refer:
            return "fail|||"
        # ARIN без «n +» отвечает списком сетей, а не записью
        text = ask(refer, "n + " + ip if "arin" in refer else ip)
        more = re.search(r"^ReferralServer:\s*r?whois://([A-Za-z0-9.-]+)", text, re.M)
        if more:
            text = ask(more.group(1), ip)
    except OSError:
        return "fail|||"
    asn = re.search(r"^(?:origin|OriginAS|aut-num):[ \t]*(AS\d+)", text, re.M | re.I)
    org = field(text, ["org-name", "OrgName", "owner", "descr", "netname", "NetName"])
    out = "ok|%s|%s|%s" % (asn.group(1).upper() if asn else "", org.replace("|", " ")[:60],
                            field(text, ["country"])[:2].upper())
    if not path:
        return out
    try:
        tmp = path + ".%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(out + "\n")
        os.replace(tmp, path)
    except OSError:
        pass
    return out


def inlist(path, ip):
    target = int(ipaddress.IPv4Address(ip))
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            words = raw.split("#", 1)[0].split()
            if not words or ":" in words[0]:
                continue
            addr, _, bits = words[0].partition("/")
            try:
                a, b, c, d = (int(x) for x in addr.split("."))
                n = int(bits) if bits else 32
            except ValueError:
                continue
            if not 0 <= n <= 32 or max(a, b, c, d) > 255:
                continue
            mask = (0xFFFFFFFF << (32 - n)) & 0xFFFFFFFF
            if target & mask == ((a << 24) | (b << 16) | (c << 8) | d) & mask:
                return "hit|" + words[0][:40]
    return "miss"


# Слои до мишени проверки с ПК. Пакеты и порядок те же, что у probe.ps1, иначе контроль
# и ПК сравнивались бы по разным проверкам
FULL = 262144


def ms(t0):
    return int((time.monotonic() - t0) * 1000)


def ping(ip):
    try:
        p = subprocess.run(["ping", "-n", "-c", "3", "-W", "2", ip], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return {"sent": 0, "got": 0, "ms": 0}
    got = re.search(r"(\d+) (?:packets )?received", p.stdout)
    avg = re.search(r"= [\d.]+/([\d.]+)/", p.stdout)
    return {"sent": 3, "got": int(got.group(1)) if got else 0, "ms": int(float(avg.group(1))) if avg else 0}


# Одна попытка: TCP, TLS со сверкой отпечатка, строка с токеном, ответ «OK <IP источника>» и 256 КБ
def conn(ip, port, token, fp):
    r = {"tcp": None, "tls": None, "fp": "", "bytes": 0, "ms": 0, "src": "", "err": ""}
    stage, t0 = "tcp", time.monotonic()
    s = None
    try:
        s = socket.create_connection((ip, port), timeout=5)
        r["tcp"] = ms(t0)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        stage, t0 = "tls", time.monotonic()
        s = ctx.wrap_socket(s)
        r["tls"] = ms(t0)
        r["fp"] = "match" if hashlib.sha256(s.getpeercert(True)).hexdigest() == fp else "mismatch"
        stage, t0 = "data", time.monotonic()
        s.sendall(b"IOF-PROBE " + token + b"\n")
        s.settimeout(6)
        buf, head, n = b"", None, 0
        while (head is None or n < FULL) and time.monotonic() - t0 < 20:
            chunk = s.recv(65536)
            if not chunk:
                r["err"] = "data: closed"
                break
            if head is not None:
                n += len(chunk)
                continue
            buf += chunk
            if b"\n" in buf:
                head, rest = buf.split(b"\n", 1)
                n = len(rest)
            elif len(buf) > 128:
                break
        if head is None or not head.startswith(b"OK "):
            r["err"] = r["err"] or "data: no answer"
        else:
            r["src"] = head[3:].decode("ascii", "replace")[:45]
            if n < FULL and not r["err"]:
                r["err"] = "data: timeout"
        r["bytes"], r["ms"] = min(n, FULL), ms(t0)
    except socket.timeout:
        r["err"] = stage + ": timeout"
    except ssl.SSLError as e:
        r["err"] = stage + ": " + (e.reason or "ssl").lower()
    except OSError as e:
        r["err"] = stage + ": " + (e.strerror or e.__class__.__name__).lower()
    finally:
        if s is not None:
            s.close()
    if r["err"].startswith("data") and not r["ms"]:
        r["ms"] = ms(t0)
    return r


# Пакет UDP с меткой: маленький или 1200 байт с заголовком как у QUIC v1 Initial
def packet(shaped, mark, nonce):
    body = mark + nonce
    if not shaped:
        return body + os.urandom(24)
    pkt = b"\xc3\x00\x00\x00\x01\x08" + os.urandom(8) + b"\x08" + os.urandom(8) + b"\x00\x44\xb0" + body
    return pkt + os.urandom(1200 - len(pkt))


def udp(ip, port, token, shaped):
    mark, zero = b"IOFP" + token, b"IOFP" + b"\0" * len(token)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((ip, port))
    sent, got, closed = [], set(), False
    for _ in range(5):
        nonce = os.urandom(8)
        sent.append(nonce)
        try:
            s.send(packet(shaped, mark, nonce))
        except OSError:
            closed = True
        time.sleep(0.05)
    s.settimeout(0.3)
    end = time.monotonic() + 2
    while time.monotonic() < end and len(got) < len(sent):
        try:
            data = s.recv(2048)
        except socket.timeout:
            continue
        except ConnectionRefusedError:
            closed = True
            continue
        except OSError:
            continue
        i = data.find(zero)
        if i >= 0:
            got.add(data[i + len(zero):i + len(zero) + 8])
    s.close()
    return {"sent": len(sent), "got": len(got & set(sent)), "closed": closed}


def trace(ip, port, fp, hy2):
    token = sys.stdin.readline().strip().encode()
    out = {"icmp": ping(ip), "conn": [conn(ip, port, token, fp) for _ in range(3)],
           "udp": udp(ip, port, token, False), "quic": udp(ip, port, token, True),
           "hy2": quic(ip, hy2) if hy2 else ""}
    return json.dumps(out, separators=(",", ":"))


def blocklist(path, minpref, protect):
    # Блок-лист для узлов: только IPv4, без частных и служебных сетей и без записей шире /minpref.
    # Первая строка: S <записей> <IPv6> <шире> <частных и служебных> <нечитаемых> <с защищёнными адресами>
    nets, v6, wide, special, bad = set(), 0, 0, 0, 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.split("#", 1)[0].strip().split()
            if not s:
                continue
            try:
                n = ipaddress.ip_network(s[0].strip(",;"), strict=False)
            except ValueError:
                bad += 1
                continue
            if n.version != 4:
                v6 += 1
            elif n.prefixlen < minpref:
                wide += 1
            elif not n.is_global:
                special += 1
            else:
                nets.add(n)
    nets = list(ipaddress.collapse_addresses(nets))
    prot = []
    for p in protect:
        try:
            prot.append(ipaddress.ip_network(p, strict=False))
        except ValueError:
            pass
    hit = sum(1 for n in nets if any(n.overlaps(p) for p in prot))
    out = [f"S {len(nets)} {v6} {wide} {special} {bad} {hit}"]
    out += [str(n.network_address) if n.prefixlen == 32 else str(n) for n in nets]
    return "\n".join(out)


mode = sys.argv[1]
if mode == "blocklist":
    print(blocklist(sys.argv[2], int(sys.argv[3]), sys.argv[4:]))
elif mode == "trace":
    print(trace(sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])))
elif mode == "quic":
    print(quic(sys.argv[2], int(sys.argv[3])))
elif mode == "banner":
    print(banner(sys.argv[2], int(sys.argv[3])))
elif mode == "whois":
    print(whois(sys.argv[2], sys.argv[3]))
elif mode == "inlist":
    print(inlist(sys.argv[2], sys.argv[3]))
EOF
)

# Список $1 (blocklist или registry) по адресу $2 в кэше $AUDIT_DIR/cache: скачивается заново не чаще
# раза в сутки и когда адрес поменяли. Неудачная загрузка оставляет прошлую копию и пометку .err
audit_fetch() {
  local f="$AUDIT_DIR/cache/$1.txt" url="$2" age=999999
  if [[ -z "$url" ]]; then return 0; fi
  if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then echo "адрес должен начинаться с http:// или https://" > "$f.err"; return 0; fi
  if [[ -s "$f" ]]; then age=$(( $(date +%s) - $(stat -c %Y "$f") )); fi
  if (( age < 86400 )) && [[ ! -f "$f.err" && "$(cat "$f.url" 2>/dev/null || true)" == "$url" ]]; then return 0; fi
  if timeout 120 curl -fsSL --max-time 100 --max-filesize 200000000 -o "$f.new" -- "$url" 2>/dev/null \
     && grep -qE '^[[:space:]]*[0-9]{1,3}(\.[0-9]{1,3}){3}' "$f.new"; then
    mv -f "$f.new" "$f"
    printf '%s\n' "$url" > "$f.url"
    rm -f "$f.err"
  else
    rm -f "$f.new"
    echo "не скачался или в нём нет адресов" > "$f.err"
  fi
}

# Состояние списка $1 для оценки: "<записей> <когда скачан>" или пусто, если копии нет
audit_list_info() {
  local f="$AUDIT_DIR/cache/$1.txt"
  if [[ -s "$f" ]]; then
    printf '%s %s' "$(grep -cE '^[[:space:]]*[0-9]{1,3}(\.[0-9]{1,3}){3}' "$f" || true)" "$(stat -c %Y "$f")"
  fi
}

# Перед опросом блока dpi: соль запуска, хэши блоков шаблона Hysteria2, списки в кэше
audit_dpi_prepare() {
  local tpl="${HY2_TEMPLATE:-/etc/hysteria/config.yaml}"
  AUDIT_SALT="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  AUDIT_TPL_SRC=""
  AUDIT_TPL=""
  if [[ -f "$tpl" ]]; then
    AUDIT_TPL_SRC="$tpl"
    AUDIT_TPL="$(n_audit_hy2_blocks "$tpl" "$AUDIT_SALT")"
  fi
  mkdir -p "$AUDIT_DIR/cache"
  chmod 700 "$AUDIT_DIR" "$AUDIT_DIR/cache"
  audit_fetch blocklist "$BLOCKLIST_URL"
  audit_fetch registry "$REGISTRY_URL"
}

# Порт $2 на адресе $1 по TCP: open, closed (отказ) или filtered (нет ответа)
audit_tcp() {
  local rc=0
  timeout 4 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null || rc=$?
  case "$rc" in
    0)   echo open ;;
    124) echo filtered ;;
    *)   echo closed ;;
  esac
}

# Ответ веб-сервера по адресу $1: "код|заголовок Server"
audit_http() {
  timeout 10 curl -sk -m 6 -o /dev/null -D - -- "$1" 2>/dev/null \
    | awk '{ sub(/\r$/, "") } NR == 1 { code = $2 } tolower($1) == "server:" { sub(/^[^:]*:[ \t]*/, ""); srv = $0 }
           END { gsub(/[|]/, " ", srv); print code "|" substr(srv, 1, 60) }' || true
}

# Ведёт ли имя $1 на адрес $2: yes, no или unknown (не имя, шаблон *.домен, DNS не ответил)
audit_points_here() {
  local got
  if ! host_ok "$1" || [[ "$1" != *.* || "$1" =~ ^[0-9.]+$ ]]; then echo unknown; return 0; fi
  got="$(timeout 5 getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u || true)"
  if [[ -z "$got" ]]; then echo no
  elif grep -qxF "$2" <<<"$got"; then echo yes
  else echo no; fi
}

# Взгляд на узел снаружи, с управляющего сервера: audit_outside <индекс узла> <факты n_audit_dpi>.
# Печатает строки x_ключ=значение:
#  x_ip (адрес узла IPv4), x_tcp80 и x_tcp443 (см. audit_tcp), x_http80 и x_http443 (см. audit_http),
#  x_cert_cn, x_cert_issuer, x_cert_self yes/no, x_cert_here (см. audit_points_here) — сертификат
#  на 443/tcp, x_hy2cert_here — ведёт ли сюда имя из сертификата Hysteria2, x_icmp yes/no/noping,
#  x_ptr, x_quic (см. AUDIT_NET_PY), x_h3 (ответ на GET по HTTP/3, если curl его умеет),
#  x_whois, x_registry и повторяющиеся x_banner=порт|состояние|приветствие для лишних портов TCP
audit_outside() {
  local i="$1" addr="${N_ADDR[$1]}" ip p s cn n st80 st443 sport=22 sni=() sans=()
  audit_parse "$2"
  ip="$addr"
  if [[ ! "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    ip="$(timeout 5 getent ahostsv4 "$addr" 2>/dev/null | awk '{ print $1; exit }' || true)"
  fi
  echo "x_ip=$ip"
  if [[ -z "$ip" ]]; then return 0; fi

  st80="$(audit_tcp "$ip" 80)"
  st443="$(audit_tcp "$ip" 443)"
  printf '%s\n' "x_tcp80=$st80" "x_tcp443=$st443"
  if have curl; then
    if [[ "$st80" == "open" ]]; then echo "x_http80=$(audit_http "http://$ip/")"; fi
    if [[ "$st443" == "open" ]]; then echo "x_http443=$(audit_http "https://$ip/")"; fi
  fi
  # Сертификат на 443/tcp. SNI — адрес узла, если это имя
  if [[ "$st443" == "open" ]] && have openssl; then
    if [[ "$addr" != "$ip" ]]; then sni=(-servername "$addr"); fi
    s="$(timeout 10 openssl s_client -connect "$ip:443" "${sni[@]}" </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer -ext subjectAltName -nameopt RFC2253 2>/dev/null || true)"
    cn="$(sed -n 's/^subject=.*CN=\([^,]*\).*/\1/p' <<<"$s" | head -n 1)"
    echo "x_cert_cn=$cn"
    echo "x_cert_issuer=$(sed -n 's/^issuer=//p' <<<"$s" | sed -E 's/.*(^|,)O=([^,]*).*/\2/; s/.*(^|,)CN=([^,]*).*/\2/' | head -n 1)"
    if [[ -n "$s" && "$(sed -n 's/^subject=//p' <<<"$s")" == "$(sed -n 's/^issuer=//p' <<<"$s")" ]]; then
      echo "x_cert_self=yes"
    else
      echo "x_cert_self=no"
    fi
    # Имя из сертификата ведёт сюда, если так у CN или у одного из первых имён SAN
    p="unknown"
    mapfile -t sans < <(grep -oE 'DNS:[^, ]+' <<<"$s" | cut -d: -f2 | head -n 5 || true)
    for n in "$cn" "${sans[@]}"; do
      if [[ "$n" == "$addr" && "$addr" != "$ip" ]]; then p="yes"; break; fi
      case "$(audit_points_here "$n" "$ip")" in
        yes) p="yes"; break ;;
        no)  p="no" ;;
      esac
    done
    echo "x_cert_here=$p"
  fi
  if [[ -n "${A[hy2_cert_cn]:-}" ]]; then echo "x_hy2cert_here=$(audit_points_here "${A[hy2_cert_cn]}" "$ip")"; fi

  if have ping; then
    if timeout 8 ping -n -c 2 -W 2 "$ip" >/dev/null 2>&1; then echo "x_icmp=yes"; else echo "x_icmp=no"; fi
  else
    echo "x_icmp=noping"
  fi
  echo "x_ptr=$(timeout 5 getent hosts "$ip" 2>/dev/null | awk '{ print $2; exit }' || true)"

  # Hysteria2 снаружи: зонд согласования версий QUIC. Настоящий GET по HTTP/3 — только если curl
  # на этом сервере собран с HTTP/3 (в Ubuntu 24.04 нет) и узел без Salamander
  p="${A[hy2_port]:-}"
  if [[ "${A[hy2]:-}" == "yes" ]] && port_ok "$p"; then
    echo "x_quic=$(timeout 12 python3 -c "$AUDIT_NET_PY" quic "$ip" "$p" 2>/dev/null || echo error)"
    if [[ "${A[hy2_obfs]:-none}" != "salamander" && "$(curl --version 2>/dev/null || true)" == *HTTP3* ]]; then
      cn="${A[hy2_cert_cn]:-}"
      if host_ok "$cn" && [[ "$cn" == *.* ]]; then
        echo "x_h3=$(timeout 12 curl -sk --http3-only -m 8 -o /dev/null -w '%{http_code}' --resolve "$cn:$p:$ip" "https://$cn:$p/" 2>/dev/null || true)"
      else
        echo "x_h3=$(timeout 12 curl -sk --http3-only -m 8 -o /dev/null -w '%{http_code}' "https://$ip:$p/" 2>/dev/null || true)"
      fi
    fi
  fi

  # Приветствия лишних портов TCP, не больше шести
  if [[ "${N_SSH[$i]}" != "local" ]]; then split_target "${N_SSH[$i]}"; sport="$T_PORT"; fi
  audit_ports "$sport"
  n=0
  for s in "${AP_EXTRA[@]}"; do
    p="${s%%/*}"
    if [[ "$s" != "$p/tcp "* ]] || (( n >= 6 )); then continue; fi
    n=$((n + 1))
    echo "x_banner=$p|$(timeout 10 python3 -c "$AUDIT_NET_PY" banner "$ip" "$p" 2>/dev/null || echo error)"
  done

  echo "x_whois=$(timeout 25 python3 -c "$AUDIT_NET_PY" whois "$ip" "$AUDIT_DIR/cache" 2>/dev/null || echo 'fail|||')"
  if [[ -n "$REGISTRY_URL" && -s "$AUDIT_DIR/cache/registry.txt" ]]; then
    echo "x_registry=$(timeout 60 python3 -c "$AUDIT_NET_PY" inlist "$AUDIT_DIR/cache/registry.txt" "$ip" 2>/dev/null || echo error)"
  fi
}

# Слово в имени сервера или PTR, которое выдаёт назначение: печатает его, код 1 — такого нет
audit_vpn_word() {
  local s="${1,,}"
  if [[ "$s" =~ (vpn|proxy|hysteria|wireguard|amnezia|vless|xray|v2ray|shadowsocks|trojan) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$s" =~ (^|[^a-z])(wg|awg|hy2|socks|tunnel)([^a-z]|$) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  else
    return 1
  fi
}

audit_int() { [[ "${1:-}" =~ ^[0-9]{1,10}$ ]]; }

# Параметры обфускации AmneziaWG из A_AWGP. AWG_PLAIN=1 — это обычный WireGuard: полей нет или
# Jc = 0, S1–S4 = 0 и H1–H4 = 1, 2, 3, 4. Иначе в AWG_BAD то, что вне границ (в AWG_BADK названия
# полей), сами значения в текст не попадают. Границы: Jc 1–128, 0 ≤ Jmin < Jmax < 1280, S1 до 1132,
# S2 до 1188, S3 до 1216, S4 до 32, S1 + 56 ≠ S2, H1–H4 — числа или диапазоны начало-конец в
# 5–2147483647 без пересечений. Числа взяты из документации GL.iNet
# (docs.gl-inet.com/router/en/4/faq/amneziawg_obfuscation_parameters), запрет пересечений H1–H4 —
# из документации Amnezia
AWG_PLAIN=0; AWG_BAD=(); AWG_BADK=()
audit_awg_check() {
  local l n j v lo hi max std=1 hstd=1 cross=0
  local -A p=() hlo=() hhi=()
  AWG_PLAIN=0; AWG_BAD=(); AWG_BADK=()
  for l in "${A_AWGP[@]}"; do p["${l%%|*}"]="${l#*|}"; done
  if [[ "${p[Jc]:-0}" != "0" ]]; then std=0; fi
  for n in 1 2 3 4; do
    if [[ "${p[S$n]:-0}" != "0" ]]; then std=0; fi
    v="${p[H$n]:-$n}"
    if [[ "$v" != "$n" && "$v" != "$n-$n" ]]; then hstd=0; fi
  done
  if (( std && hstd )); then AWG_PLAIN=1; return 0; fi

  v="${p[Jc]:-}"
  if ! audit_int "$v" || (( 10#$v < 1 || 10#$v > 128 )); then
    AWG_BADK+=("Jc"); AWG_BAD+=("Jc: нужно от 1 до 128, иначе мусорные пакеты перед рукопожатием не идут")
  fi
  lo="${p[Jmin]:-}"; hi="${p[Jmax]:-}"
  if ! audit_int "$lo" || ! audit_int "$hi" || (( 10#$lo >= 10#$hi || 10#$hi >= 1280 )); then
    AWG_BADK+=("Jmin и Jmax"); AWG_BAD+=("Jmin и Jmax: нужно 0 ≤ Jmin < Jmax < 1280")
  fi
  for n in 1 2 3 4; do
    case "$n" in 1) max=1132 ;; 2) max=1188 ;; 3) max=1216 ;; *) max=32 ;; esac
    v="${p[S$n]:-}"
    # S3 и S4 появились в AmneziaWG 2.0, у контейнера 1.x их нет
    if [[ -z "$v" ]] && (( n > 2 )); then continue; fi
    if ! audit_int "$v" || (( 10#$v > max )); then
      AWG_BADK+=("S$n"); AWG_BAD+=("S$n: нужно от 0 до $max")
    elif (( n <= 2 && 10#$v == 0 )); then
      AWG_BADK+=("S$n"); AWG_BAD+=("S$n выключен: пакет рукопожатия той же длины, что у WireGuard")
    fi
  done
  if audit_int "${p[S1]:-}" && audit_int "${p[S2]:-}" && (( 10#${p[S1]} + 56 == 10#${p[S2]} )); then
    AWG_BADK+=("S1 и S2"); AWG_BAD+=("S1 + 56 = S2: пакеты начала и ответа рукопожатия выходят одной длины")
  fi
  if (( hstd )); then
    AWG_BADK+=("H1–H4"); AWG_BAD+=("H1–H4 как у WireGuard (1, 2, 3, 4): заголовки пакетов не меняются")
    return 0
  fi
  for n in 1 2 3 4; do
    v="${p[H$n]:-}"
    if [[ "$v" =~ ^([0-9]{1,10})(-([0-9]{1,10}))?$ ]]; then
      lo=$((10#${BASH_REMATCH[1]}))
      hi="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
      hi=$((10#$hi))
      hlo[$n]=$lo; hhi[$n]=$hi
      if (( lo > hi || lo < 5 || hi > 2147483647 )); then
        AWG_BADK+=("H$n"); AWG_BAD+=("H$n: нужно число или диапазон начало-конец в пределах 5–2147483647")
      fi
    else
      AWG_BADK+=("H$n"); AWG_BAD+=("H$n не задан или записан не числом и не диапазоном начало-конец")
    fi
  done
  for n in 1 2 3; do
    for (( j = n + 1; j <= 4; j++ )); do
      if [[ -n "${hlo[$n]:-}" && -n "${hlo[$j]:-}" ]] && (( hlo[$n] <= hhi[$j] && hlo[$j] <= hhi[$n] )); then cross=1; fi
    done
  done
  if (( cross )); then AWG_BADK+=("H1–H4"); AWG_BAD+=("H1–H4: диапазоны пересекаются, а должны быть раздельными"); fi
}

# Оценка блока «Защита от РКН» для узла с индексом $1 по фактам $2 (вывод n_audit_dpi и
# audit_outside). Там, где правильного ответа нет, ставится «внимание» или «нет данных» с
# объяснением компромисса. Секретов в тексте нет: только «задано» и совпадения
audit_eval_dpi() {
  local i="$1" name="${N_NAME[$1]}" target="${N_SSH[$1]}" addr="${N_ADDR[$1]}" where="На узле от root:" me=""
  local now ip port="" hy2=0 obfs=0 masq="none" k v s st val hint cmd n w at diff d=() same=() open=() shut=()
  local conf="/etc/hysteria/config.yaml" restart="systemctl restart hysteria-server"
  local -A tpl=() mine=()
  audit_parse "$2"
  now="$(audit_num "${A[now]:-}")"
  ip="${A[x_ip]:-}"
  if [[ "$target" == "local" ]]; then
    where="На этом сервере от root:"
    me="Проверено с самого управляющего сервера, а не снаружи: файрвол на пути не участвует"
  fi

  # Hysteria2
  if [[ "${A[hy2]:-}" != "yes" ]]; then
    for k in hy2_mode hy2_masq hy2_quic hy2_port hy2_hop hy2_template; do
      audit_chk "$k" none "Hysteria2 на узле не установлена"
    done
  else
    hy2=1
    port="${A[hy2_port]:-443}"
    masq="${A[hy2_masq]:-none}"
    if [[ "${A[hy2_obfs]:-none}" == "salamander" ]]; then obfs=1; fi

    if (( obfs )) && [[ "${A[hy2_obfs_pass]:-}" != "set" ]]; then
      audit_chk hy2_mode warn "Salamander включён, но пароль не задан" "" \
        "Задай obfs.salamander.password в $conf и перезапусти службу. Тот же пароль должен быть в ссылках клиентов: после правки на управляющем сервере sudo iof hy2 refresh. $where" \
        "nano $conf && $restart"
    elif (( obfs )); then
      audit_chk hy2_mode good "Salamander: трафик похож на случайный шум" \
        "Другой вариант — без Salamander с masquerade: сервер выглядит как сайт с HTTP/3. Это иной компромисс, а не улучшение"
    elif [[ "$masq" != "none" ]]; then
      audit_chk hy2_mode good "без Salamander, с masquerade: сервер выглядит как сайт с HTTP/3" \
        "QUIC к зарубежным адресам фильтры могут резать. Salamander прячет QUIC, но делает трафик непохожим ни на что: это иной компромисс, а не улучшение"
    else
      audit_chk hy2_mode warn "ни Salamander, ни masquerade: на запрос по HTTP/3 сервер отвечает 404" "" \
        "Выбери одно. Masquerade: сервер показывает зонду чужой сайт, ссылки клиентов не меняются (команда ниже, адрес сайта замени на тот, что открывается с узла). Salamander: блок obfs в конфиге и новые ссылки клиентам. Чтобы новые узлы ставились так же, внеси блок и в шаблон на управляющем сервере. $where" \
        "$(audit_lines "printf '\nmasquerade:\n  type: proxy\n  proxy:\n    url: https://example.org/\n    rewriteHost: true\n' >> $conf" "$restart")"
    fi

    d=()
    if [[ -n "${A[x_h3]:-}" ]]; then d+=("GET по HTTP/3 с управляющего сервера: ответ ${A[x_h3]}"); fi
    if (( obfs )); then
      val="под Salamander masquerade снаружи не виден"
      if [[ "$masq" != "none" ]]; then val+=" (в конфиге: $masq)"; fi
      audit_chk hy2_masq none "$val"
    else
      case "$masq" in
        proxy)
          s="${A[hy2_masq_url]:-}"
          v="${A[hy2_masq_code]:-}"
          if [[ "$v" =~ ^[23] ]]; then
            audit_chk hy2_masq good "proxy на $s, цель с узла отвечает ($v)" "$(audit_lines "${d[@]}")"
          elif [[ -z "$v" ]]; then
            audit_chk hy2_masq none "proxy на $s, цель проверить нечем: на узле нет curl" "$(audit_lines "${d[@]}")"
          else
            audit_chk hy2_masq warn "proxy на $s, цель с узла не отвечает (код ${v/#000/нет ответа})" "$(audit_lines "${d[@]}")" \
              "Зонд вместо сайта получит ошибку. Проверь адрес в masquerade.proxy.url или выбери другой сайт. $where" \
              "curl -sI -m 8 '$s' | head -n 1"
          fi ;;
        file)
          if [[ "${A[hy2_masq_dir]:-}" == "yes" ]]; then
            audit_chk hy2_masq good "file: сервер отдаёт файлы из каталога" "$(audit_lines "${d[@]}")"
          else
            audit_chk hy2_masq warn "file: каталога из masquerade.file.dir на узле нет" "$(audit_lines "${d[@]}")" \
              "Зонд вместо сайта получит ошибку. Создай каталог с файлами сайта или поправь путь в $conf."
          fi ;;
        string)
          audit_chk hy2_masq good "string: сервер отдаёт заданный текст" "$(audit_lines "${d[@]}")" ;;
        none)
          audit_chk hy2_masq warn "не настроен: на запрос по HTTP/3 сервер отвечает 404" "$(audit_lines "${d[@]}")" \
            "Как добавить, написано в проверке «Режим маскировки»." ;;
        *)
          audit_chk hy2_masq none "тип $masq, оценки для него нет" "$(audit_lines "${d[@]}")" ;;
      esac
    fi

    d=("$me")
    if [[ "${A[hy2_state]:-}" != "active" ]]; then d+=("Служба hysteria-server не работает (${A[hy2_state]:-нет данных})"); fi
    v="${A[x_quic]:-}"
    if [[ -z "$ip" ]]; then
      audit_chk hy2_quic none "адрес узла $addr не определился как IPv4"
    elif [[ -z "$v" || "$v" == "error" ]]; then
      audit_chk hy2_quic none "зонд не выполнился"
    elif (( obfs )) && [[ "$v" == "vn" ]]; then
      audit_chk hy2_quic warn "Salamander в конфиге, а порт $port/udp отвечает как обычный сервер QUIC" "$(audit_lines "${d[@]}")" \
        "Похоже, служба не перезапущена после правки конфига и работает без Salamander. $where" "$restart"
    elif (( obfs )) && [[ "$v" == "reply" ]]; then
      audit_chk hy2_quic good "порт $port/udp ответил не как QUIC: так и выглядит Salamander" "$(audit_lines "${d[@]}")"
    elif (( obfs )); then
      audit_chk hy2_quic good "порт $port/udp на зонд QUIC не отвечает: так и выглядит Salamander" \
        "$(audit_lines "${d[@]}" "Доходит ли до узла UDP, под Salamander этот зонд не показывает")"
    elif [[ "$v" == "vn" ]]; then
      audit_chk hy2_quic good "порт $port/udp отвечает как сервер QUIC (согласование версий)" "$(audit_lines "${d[@]}")"
    else
      case "$v" in
        closed) val="порт $port/udp закрыт: на нём никто не слушает или файрвол отвечает отказом" ;;
        reply)  val="порт $port/udp ответил не как QUIC" ;;
        *)      val="порт $port/udp на зонд QUIC не ответил" ;;
      esac
      audit_chk hy2_quic warn "$val" "$(audit_lines "${d[@]}")" \
        "UDP от управляющего сервера до узла не дошёл: порт закрыт файрволом узла или хостера, либо QUIC режется по пути. Клиенты могут видеть то же самое. $where" \
        "$(audit_lines "systemctl is-active hysteria-server" "ss -uln | grep ':$port '" "ufw status | grep -w $port")"
    fi

    if (( obfs )); then
      audit_chk hy2_port none "$port/udp: под Salamander трафик не похож на QUIC на любом порту"
    elif [[ "$port" == "443" ]]; then
      audit_chk hy2_port good "443/udp, как у HTTP/3"
    else
      audit_chk hy2_port warn "$port/udp, а HTTP/3 обычно на 443" "" \
        "QUIC на нестандартном порту заметнее. Зато 443/udp фильтруют чаще: если так задумано, оставь. Сменить порт: команда на узле, затем на управляющем сервере sudo iof hy2 refresh (ссылки клиентов изменятся). $where" \
        "sed -i -E 's/^listen:.*/listen: :443/' $conf && $restart"
    fi

    # Смена портов: диапазон в listen, его Hysteria2 перенаправляет сама (iof hy2 hop). Правила,
    # поставленные вручную, iof видит, но не трогает
    s="${A[hy2_range]:-}"
    v="${A[hy2_ver]:-}"
    if [[ -n "$s" ]]; then
      d=("$me" "$(hop_groups_line)" "Если у хостера свой файрвол в панели, в нём должен быть открыт UDP $s")
      if grep -qxF "$s" <<<"${A[hy2_hop]//,/$'\n'}"; then
        audit_chk hy2_hop good "диапазон $s на порт $port, правила ставит сама Hysteria2" "$(audit_lines "${d[@]}")" \
          "" "" "hop_off"
      else
        audit_chk hy2_hop warn "диапазон $s в конфиге, а правил перенаправления нет" "$(audit_lines "${d[@]}")" \
          "Клиенты со списком портов в ссылке попадают на закрытые порты. Служба не перезапущена после правки конфига, Hysteria2 старше $HY2_HOP_MIN или у службы нет прав на правила (CAP_NET_ADMIN в юните). Включить заново с проверкой и откатом при неудаче — на управляющем сервере:" \
          "sudo iof hy2 hop on $name --ports $s" "hop_on hop_off"
      fi
    elif [[ -n "${A[hy2_hop]:-}" ]]; then
      audit_chk hy2_hop good "диапазон ${A[hy2_hop]//,/, } перенаправлен на порт $port правилами вне iof" \
        "$(audit_lines "$me" "Такие правила iof не включает и не снимает: после перезагрузки их надо вернуть самому")"
    elif [[ -n "$v" ]] && ! ver_ge "$v" "$HY2_HOP_MIN"; then
      audit_chk hy2_hop warn "нет: клиенты всегда ходят на порт $port" "Hysteria2 на узле: $v" \
        "Смене портов нужна Hysteria2 от $HY2_HOP_MIN: в старых версиях её правила заворачивали и исходящий UDP самого узла. Сначала обнови её (бинарник и юнит сохраняются на узле и возвращаются, если служба не поднимется), потом включи. На управляющем сервере:" \
        "$(audit_lines "sudo iof hy2 upgrade $name" "sudo iof hy2 hop on $name")" "hy2_upgrade"
    else
      audit_chk hy2_hop warn "нет: клиенты всегда ходят на порт $port" "" \
        "Включить: в listen добавится диапазон $HY2_HOP (HY2_HOP в /root/iof/iof.env), основной порт $port останется, выданные ссылки продолжат работать как раньше. Список портов в ссылках получат только группы с --hop: такие ссылки импортируют Hiddify с 5.5.5 и официальный клиент, v2rayN и Hiddify старше — нет. На управляющем сервере:" \
        "$(audit_lines "sudo iof hy2 hop on $name" "sudo iof hy2 add \"Подпись\" --hop")" "hop_on"
    fi

    # Блоки конфига узла против блоков шаблона, по хэшам этого запуска
    if [[ -z "$AUDIT_TPL_SRC" ]]; then
      audit_chk hy2_template none "шаблона на управляющем сервере нет" \
        "Шаблон — /etc/hysteria/config.yaml управляющего сервера или файл из HY2_TEMPLATE в /root/iof/iof.env"
    else
      while IFS= read -r s; do
        s="${s#hy2_block=}"
        if [[ "$s" == *"|"* ]]; then tpl["${s%%|*}"]="${s#*|}"; fi
      done <<<"$AUDIT_TPL"
      for s in "${A_BLOCK[@]}"; do mine["${s%%|*}"]="${s#*|}"; done
      d=()
      for k in "${!mine[@]}"; do
        if [[ -z "${tpl[$k]:-}" ]]; then d+=("$k (в шаблоне нет)")
        elif [[ "${tpl[$k]}" != "${mine[$k]}" ]]; then d+=("$k"); fi
      done
      for k in "${!tpl[@]}"; do
        if [[ -z "${mine[$k]:-}" ]]; then d+=("$k (на узле нет)"); fi
      done
      if (( ${#d[@]} == 0 )); then
        audit_chk hy2_template good "совпадает с шаблоном" "Шаблон: $AUDIT_TPL_SRC. Пользователи auth.userpass не сравниваются: на узлах они свои"
      else
        val="$(printf '%s\n' "${d[@]}" | sort | paste -sd, | sed 's/,/, /g')"
        audit_chk hy2_template warn "отличается от шаблона, блоки: $val" "Шаблон: $AUDIT_TPL_SRC" \
          "Если правки на узле нужны, внеси их и в шаблон. Вернуть узлу конфиг по шаблону — команда ниже. При auth userpass пользователи узла создадутся заново с новыми паролями: ссылки на этот узел изменятся, раздай их снова (sudo iof hy2 show). На управляющем сервере:" \
          "sudo iof hy2 install $name --force"
      fi
    fi
  fi

  # AmneziaWG
  s="${A[awg_c]:-}"
  case "${A[awg]:-}" in
    running)
      audit_awg_check
      d=("Контейнер $s, интерфейс ${A[awg_if]:-?}")
      v=""
      for k in "${A_AWGI[@]}"; do
        if [[ "$k" == *"|set" ]]; then v+="${v:+, }I${k%%|*}"; fi
      done
      if (( ${#A_AWGI[@]} > 0 )); then d+=("Пакеты-подписи I1–I5: ${v:+заданы }${v:-не заданы}"); fi
      if (( AWG_PLAIN )); then
        audit_chk awg_params crit "как у обычного WireGuard: параметры обфускации не заданы" "$(audit_lines "${d[@]}")" \
          "Такой трафик фильтры узнают по первому пакету. Параметры задаёт приложение Amnezia при установке: поставь на сервер из приложения протокол AmneziaWG вместо WireGuard и выдай ключи заново. На управляющем сервере:" \
          "sudo iof awg refresh"
      elif (( ${#AWG_BAD[@]} > 0 )); then
        val="$(printf '%s\n' "${AWG_BADK[@]}" | awk '!seen[$0]++' | paste -sd, | sed 's/,/, /g')"
        audit_chk awg_params warn "вне допустимых границ: $val" "$(audit_lines "${d[@]}" "${AWG_BAD[@]}")" \
          "Параметры должны совпадать на сервере и у всех клиентов, поэтому вручную их не правят. Переустанови AmneziaWG на сервере из приложения Amnezia (оно подберёт значения в границах) и выдай ключи заново. На управляющем сервере:" \
          "sudo iof awg refresh"
      else
        audit_chk awg_params good "заданы и в допустимых границах" "$(audit_lines "${d[@]}")"
      fi

      v="${A[awg_hash]:-}"
      same=()
      for k in "${!AUDIT_AWG[@]}"; do
        if [[ "$k" != "$name" && "${AUDIT_AWG[$k]}" == "$v" ]]; then same+=("$k"); fi
      done
      if [[ -z "$v" ]]; then
        audit_chk awg_same none "параметров обфускации в конфиге нет, сравнивать нечего"
      elif (( ${#AUDIT_AWG[@]} < 2 )); then
        audit_chk awg_same none "сравнивать не с чем: в этой проверке AmneziaWG только на этом узле" \
          "Сравнение идёт внутри одной проверки. Проверить все узлы: sudo iof audit run dpi"
      elif (( ${#same[@]} > 0 )); then
        val="$(printf '%s\n' "${same[@]}" | sort | paste -sd, | sed 's/,/, /g')"
        audit_chk awg_same warn "такие же параметры на: $val" "" \
          "Так бывает, если серверы ставили копированием настроек. Свои параметры узел получит, если переустановить на нём AmneziaWG из приложения Amnezia. После этого на управляющем сервере:" \
          "sudo iof awg refresh"
      else
        audit_chk awg_same good "отличаются от остальных узлов (сравнено узлов: ${#AUDIT_AWG[@]})"
      fi ;;
    stopped)
      audit_chk awg_params none "контейнер $s остановлен"
      audit_chk awg_same none "контейнер $s остановлен" ;;
    noconf)
      audit_chk awg_params none "в контейнере $s нет конфига awg0.conf или wg0.conf"
      audit_chk awg_same none "в контейнере $s нет конфига" ;;
    none)
      audit_chk awg_params none "AmneziaWG на узле не установлен"
      audit_chk awg_same none "AmneziaWG на узле не установлен" ;;
    *)
      audit_chk awg_params none "нет данных"
      audit_chk awg_same none "нет данных" ;;
  esac

  # Что видно снаружи
  if [[ -z "$ip" ]]; then
    for k in tcp_web tls_cert icmp banners; do
      audit_chk "$k" none "адрес узла $addr не определился как IPv4"
    done
  else
    # Порты 80 и 443/tcp: кто на них отвечает
    open=(); shut=()
    w=1
    for n in 80 443; do
      case "${A[x_tcp$n]:-}" in
        open)
          s="${A[x_http$n]:-}"
          v="$n/tcp"
          if [[ "${A[hy2_http]:-}" == "$n" || "${A[hy2_https]:-}" == "$n" ]]; then
            v+=" masquerade Hysteria2"
          else
            w=0
            if [[ -n "${s#*|}" ]]; then v+=" ${s#*|}"; else v+=" служба без заголовка Server"; fi
          fi
          if [[ -n "${s%%|*}" ]]; then v+=" (ответ ${s%%|*})"; fi
          open+=("$v") ;;
        filtered) shut+=("$n/tcp не отвечает") ;;
        *)        shut+=("$n/tcp закрыт") ;;
      esac
    done
    d=("$me")
    if (( ${#open[@]} == 0 )); then
      if (( hy2 && ! obfs )) && [[ "$masq" != "none" ]]; then
        audit_chk tcp_web warn "закрыты, а на $port/udp сервер изображает сайт с HTTP/3" "$(audit_lines "${d[@]}")" \
          "Настоящий сайт с HTTP/3 отвечает и по TCP. В Hysteria2 для этого есть masquerade.listenHTTPS и listenHTTP: команда добавляет их в блок masquerade. Если включён файрвол, открой 80/tcp и 443/tcp. $where" \
          "sed -i '/^masquerade:/a\\  listenHTTP: :80\\n  listenHTTPS: :443\\n  forceHTTPS: true' $conf && $restart"
      else
        audit_chk tcp_web good "закрыты: $(audit_list "${shut[@]}")" "$(audit_lines "${d[@]}")"
      fi
    elif (( w )); then
      audit_chk tcp_web good "отвечает $(audit_list "${open[@]}")" "$(audit_lines "${d[@]}" "${shut[@]}")"
    else
      audit_chk tcp_web none "отвечает $(audit_list "${open[@]}")" \
        "$(audit_lines "${d[@]}" "${shut[@]}" "Это не Hysteria2: что увидит зонд, зависит от этой службы. Оценки здесь нет, смотри проверку «Сертификат»")"
    fi

    # Сертификат: тот, что на 443/tcp, иначе тот, что Hysteria2 показывает при рукопожатии QUIC
    hint="Сертификат на имя чужого сайта снаружи выглядит подделкой. Варианты: свой домен и блок acme в конфиге Hysteria2 (сертификат выдаст Let's Encrypt, в ссылках клиентов пропадёт insecure) или Salamander, под которым рукопожатие снаружи не видно."
    if [[ "${A[x_tcp443]:-}" == "open" && -n "${A[x_cert_cn]:-}${A[x_cert_issuer]:-}" ]]; then
      s="${A[x_cert_cn]:-без имени}"
      d=("$me")
      if [[ "${A[hy2_https]:-}" == "443" ]]; then d+=("На 443/tcp отвечает masquerade Hysteria2 со своим сертификатом"); fi
      if [[ "${A[x_cert_self]:-}" != "yes" ]]; then
        if [[ "${A[x_cert_here]:-}" == "no" ]]; then
          audit_chk tls_cert warn "443/tcp: выдан ${A[x_cert_issuer]:-УЦ} на $s, но это имя ведёт не на адрес узла" "$(audit_lines "${d[@]}")" \
            "Проверь запись DNS для $s: она должна указывать на $ip."
        else
          audit_chk tls_cert good "443/tcp: выдан ${A[x_cert_issuer]:-УЦ} на $s" "$(audit_lines "${d[@]}")"
        fi
      elif [[ "${A[x_cert_here]:-}" == "yes" ]]; then
        audit_chk tls_cert none "443/tcp: самоподписанный на $s, имя ведёт на этот адрес" \
          "$(audit_lines "${d[@]}" "Браузер такому сертификату не доверяет, но и чужим сайтом сервер не притворяется")"
      elif [[ "$s" == *.* ]]; then
        audit_chk tls_cert warn "443/tcp: самоподписанный на чужое имя $s" "$(audit_lines "${d[@]}")" "$hint"
      else
        audit_chk tls_cert none "443/tcp: самоподписанный, без имени сайта ($s)" "$(audit_lines "${d[@]}")"
      fi
    elif [[ "${A[x_tcp443]:-}" == "open" ]]; then
      audit_chk tls_cert none "443/tcp открыт, но сертификат с него получить не удалось" "$me"
    elif (( hy2 && obfs )); then
      audit_chk tls_cert none "снаружи не виден: 443/tcp закрыт, рукопожатие QUIC скрыто под Salamander"
    elif (( hy2 )) && [[ "${A[hy2_acme]:-}" == "yes" ]]; then
      audit_chk tls_cert good "Hysteria2 получает сертификат по ACME на своё имя"
    elif (( hy2 )) && [[ -n "${A[hy2_cert_cn]:-}" ]]; then
      s="${A[hy2_cert_cn]}"
      d=("Сертификат Hysteria2 виден при рукопожатии QUIC на $port/udp")
      if [[ "${A[hy2_cert_self]:-}" != "yes" ]]; then
        audit_chk tls_cert good "Hysteria2: выдан удостоверяющим центром на $s" "$(audit_lines "${d[@]}")"
      elif [[ "${A[x_hy2cert_here]:-}" == "yes" ]]; then
        audit_chk tls_cert none "Hysteria2: самоподписанный на $s, имя ведёт на этот адрес" "$(audit_lines "${d[@]}")"
      elif [[ "$s" == *.* ]]; then
        audit_chk tls_cert warn "Hysteria2: самоподписанный на чужое имя $s" "$(audit_lines "${d[@]}")" "$hint"
      else
        audit_chk tls_cert none "Hysteria2: самоподписанный, без имени сайта ($s)" "$(audit_lines "${d[@]}")"
      fi
    else
      audit_chk tls_cert none "снаружи не виден: 443/tcp закрыт"
    fi

    case "${A[x_icmp]:-}" in
      yes)    audit_chk icmp good "отвечает" "$me" ;;
      no)     audit_chk icmp none "не отвечает: ICMP закрыт на узле, у хостера или режется по пути" ;;
      noping) audit_chk icmp none "на управляющем сервере нет ping: apt install iputils-ping" ;;
      *)      audit_chk icmp none "нет данных" ;;
    esac

    # Лишние порты TCP: открыты ли снаружи и чем отвечают
    s=22
    if [[ "$target" != "local" ]]; then split_target "$target"; s="$T_PORT"; fi
    audit_ports "$s"
    open=(); shut=()
    for s in "${A_BANNER[@]}"; do
      IFS='|' read -r n st v <<<"$s"
      if [[ "$st" == "open" ]]; then open+=("$n/tcp${v:+ ($v)}"); else shut+=("$n/tcp"); fi
    done
    d=("$me")
    for s in "${AP_EXTRA[@]}"; do
      if [[ "$s" == *"/udp "* ]]; then d+=("Слушает UDP, приветствия у него нет: $s"); fi
    done
    if (( ${#AP_EXTRA[@]} == 0 )); then
      if (( ${#A_LISTEN[@]} == 0 )); then audit_chk banners none "нет данных (нет ss)"
      else audit_chk banners good "лишних портов нет"; fi
    elif (( ${#open[@]} > 0 )); then
      audit_chk banners warn "снаружи открыты: $(audit_list "${open[@]}")" "$(audit_lines "${d[@]}")" \
        "Останови службу или закрой порт файрволом: что это за порты, показывает проверка «Слушающие порты» в аудите сервера. $where" \
        "$(audit_lines "ss -tulnp | grep -E ':($(audit_lines "${AP_XP[@]}" | tr '\037' '|')) '" "systemctl disable --now <служба>")"
    elif (( ${#shut[@]} > 0 )); then
      audit_chk banners good "лишние порты снаружи закрыты: $(audit_list "${shut[@]}")" "$(audit_lines "${d[@]}")"
    else
      audit_chk banners none "лишние порты только UDP, приветствий у них нет" "$(audit_lines "${d[@]}")"
    fi
  fi

  # Имя сервера и PTR
  s="${A[hostname]:-}"
  v="${A[x_ptr]:-}"
  if [[ -z "$s" && -z "$v" ]]; then
    audit_chk names none "нет данных"
  else
    val="имя сервера: ${s:-нет данных}, PTR: ${v:-нет}"
    d=(); hint=""; cmd=""
    if w="$(audit_vpn_word "$s")"; then
      d+=("В имени сервера есть «$w»")
      hint="Имя сервера меняется командой ниже. $where"
      cmd="hostnamectl set-hostname srv-${name//[^A-Za-z0-9]/-}"
      if audit_vpn_word "$cmd" >/dev/null; then cmd="hostnamectl set-hostname server1"; fi
    fi
    if w="$(audit_vpn_word "$v")"; then
      d+=("В PTR есть «$w»")
      hint="PTR (reverse DNS) меняется в панели хостера. ${hint}"
    fi
    if (( ${#d[@]} > 0 )); then audit_chk names warn "$val" "$(audit_lines "${d[@]}")" "$hint" "$cmd"
    else audit_chk names good "$val"; fi
  fi

  case "${A[web]:-}" in
    none)     audit_chk panel good "панели на узле нет" ;;
    loopback) audit_chk panel good "слушает только ${A[web_addr]:-127.0.0.1}" ;;
    any)
      audit_chk panel crit "слушает внешний адрес: ${A[web_addr]:-?}" "" \
        "Верни панель на 127.0.0.1 и открывай её через SSH-туннель со своего компьютера: ssh -L 8088:127.0.0.1:8088 root@$addr. $where" \
        "sed -i -E 's/--listen [^ ]+/--listen 127.0.0.1:8088/' /etc/systemd/system/iof-web.service && systemctl daemon-reload && systemctl restart iof-web" ;;
    unknown)  audit_chk panel none "служба iof-web запущена, но её порт не найден" ;;
    *)        audit_chk panel none "нет данных" ;;
  esac

  # Блок-лист сканеров: iof block on применяет BLOCKLIST_URL на узле, iof block update обновляет
  s="$(audit_list_info blocklist)"
  k="no"
  if [[ "${A[block_set]:-}" == "yes" || "${A[block_chain]:-}" == "yes" || "${A[block_hook]:-}" == "yes" || -n "${A[block_at]:-}" ]]; then k="yes"; fi
  at="$(audit_num "${A[block_at]:-}")"
  if [[ "${A[block_ipt]:-}" == "no" ]]; then
    audit_chk blocklist none "на узле нет iptables" "" \
      "Блок-лист iof ставит правилом iptables с набором ipset (на Ubuntu 24.04 iptables работает поверх nftables). Узел только с nftables так не защитить, а своих правил nftables iof не пишет."
  elif [[ -z "$BLOCKLIST_URL" ]]; then
    if [[ "$k" == "yes" ]]; then
      audit_chk blocklist warn "применён, но BLOCKLIST_URL пуст: список больше не обновляется" "" \
        "Задай BLOCKLIST_URL в /root/iof/iof.env или сними список с узла. На управляющем сервере:" \
        "sudo iof block off $name" "block_off"
    else
      audit_chk blocklist none "список не задан: BLOCKLIST_URL в /root/iof/iof.env пуст" \
        "Формат списка: текст, по одному IP или CIDR в строке, # — комментарий. Пример: BLOCKLIST_URL=\"https://example.org/scanners.txt\". Применяет его на узле sudo iof block on <узел>"
    fi
  elif [[ -z "$s" ]]; then
    v=""
    if [[ "$k" == "yes" ]]; then v="block_off"; fi
    audit_chk blocklist none "список не скачался: проверь BLOCKLIST_URL в /root/iof/iof.env" \
      "Проверить вручную на управляющем сервере: curl -fsSL \"\$BLOCKLIST_URL\" | head" "" "" "$v"
  else
    d=("В исходном списке строк с адресами: ${s%% *}, скачан $(audit_when "${s##* }")")
    if [[ -f "$AUDIT_DIR/cache/blocklist.txt.err" ]]; then d+=("Последняя загрузка не удалась, это прошлая копия"); fi
    hint="Обновлять раз в сутки: на управляющем сервере sudo crontab -e, строка 15 5 * * * /usr/local/bin/iof block update >/dev/null 2>&1"
    if [[ "${A[block_set]:-}" == "yes" && "${A[block_chain]:-}" == "yes" && "${A[block_hook]:-}" == "yes" && "${A[block_svc]:-}" == "enabled" ]]; then
      val="применён: записей $(audit_num "${A[block_entries]:-}")"
      d+=("Не блокируются: узлы из nodes.conf, этот сервер, BLOCK_ALLOW, сессии SSH на узле во время применения")
      if (( at > 0 && now - at > 7 * 86400 )); then
        audit_chk blocklist warn "$val, список скачан $(audit_when "$at")" "$(audit_lines "${d[@]}")" \
          "Список на узле старше недели, а адреса сканеров меняются. Обновить сейчас: на управляющем сервере sudo iof block update $name. $hint" \
          "sudo iof block update $name" "block_update block_off"
      else
        audit_chk blocklist good "$val, список скачан $(audit_when "$at")" "$(audit_lines "${d[@]}")" "" "" "block_update block_off"
      fi
    elif [[ "$k" == "yes" ]]; then
      audit_chk blocklist warn "применён не полностью: набор iof-block ${A[block_set]:-no}, цепочка IOF-BLOCK ${A[block_chain]:-no}, переход из PREROUTING ${A[block_hook]:-no}, служба iof-block ${A[block_svc]:-нет}" \
        "$(audit_lines "${d[@]}")" "Пакеты с адресов из списка отбрасываются, только когда есть и набор, и цепочка, и переход в неё, а после перезагрузки список возвращает служба. Применить заново — на управляющем сервере:" \
        "sudo iof block on $name" "block_on block_off"
    else
      audit_chk blocklist warn "на узле не применён" "$(audit_lines "${d[@]}")" \
        "Применить: пакеты с адресов из списка узел будет отбрасывать раньше NAT, ufw и Docker, в том числе на портах контейнеров и ретранслятора. Узлы из nodes.conf, этот сервер, BLOCK_ALLOW и текущие сессии SSH на узле не блокируются, записи шире /$BLOCK_MIN_PREFIX и IPv6 пропускаются. $hint. На управляющем сервере:" \
        "sudo iof block on $name" "block_on"
    fi
  fi

  # Репутация адреса: сеть и хостер по whois, адрес в выгрузке реестра
  IFS='|' read -r st v s k <<<"${A[x_whois]:-}"
  if [[ -z "$ip" ]]; then
    audit_chk asn none "не определён: адрес узла $addr не IPv4"
  elif [[ "$st" == "private" ]]; then
    audit_chk asn none "не определён: $ip — частный адрес, в whois его нет"
  elif [[ "$st" == "ok" && -n "$v" ]]; then
    audit_chk asn good "$v${s:+, $s}${k:+ ($k)}" "Адрес $ip, данные whois регионального реестра"
  elif [[ "$st" == "ok" ]]; then
    audit_chk asn none "не определён" "Реестр не отдал номер AS для $ip${s:+. Сеть: $s}${k:+ ($k)}"
  else
    audit_chk asn none "не определён" "whois не ответил: с управляющего сервера должен быть доступен порт 43 (whois.iana.org и региональный реестр)"
  fi

  s="$(audit_list_info registry)"
  v="${A[x_registry]:-}"
  if [[ -z "$REGISTRY_URL" ]]; then
    audit_chk registry none "выгрузка не задана: REGISTRY_URL в /root/iof/iof.env пуст" \
      "Формат: текст, по одному IP или CIDR в строке, # — комментарий. Пример: REGISTRY_URL=\"https://example.org/registry-ips.txt\""
  elif [[ -z "$s" ]]; then
    audit_chk registry none "выгрузка не скачалась: проверь REGISTRY_URL в /root/iof/iof.env" \
      "Проверить вручную на управляющем сервере: curl -fsSL \"\$REGISTRY_URL\" | head"
  elif [[ -z "$ip" ]]; then
    audit_chk registry none "адрес узла $addr не IPv4, а выгрузка проверяется только по IPv4"
  else
    d=("В выгрузке записей: ${s%% *}, скачана $(audit_when "${s##* }")")
    if [[ -f "$AUDIT_DIR/cache/registry.txt.err" ]]; then d+=("Последняя загрузка не удалась, это прошлая копия"); fi
    case "$v" in
      hit\|*)
        audit_chk registry crit "адрес $ip есть в выгрузке (запись ${v#hit|})" "$(audit_lines "${d[@]}")" \
          "У провайдеров, которые блокируют по реестру, узел недоступен. Помогает только другой адрес: новый IP у хостера или новый сервер (страница «Добавить сервер»). Старый узел убирается так, на управляющем сервере:" \
          "$(audit_lines "sudo iof node del $name" "sudo iof refresh")" ;;
      miss) audit_chk registry good "адреса $ip в выгрузке нет" "$(audit_lines "${d[@]}")" ;;
      *)    audit_chk registry none "проверка по выгрузке не выполнилась" "$(audit_lines "${d[@]}")" ;;
    esac
  fi

  # Гигиена: что остаётся в журналах и время
  if [[ -z "${A[jd_usage]:-}${A[jd_oldest]:-}${A[jd_retention]:-}" ]]; then
    audit_chk journald none "нет данных (нет journalctl)"
  else
    d=()
    if [[ -n "${A[jd_usage]:-}" ]]; then d+=("Журнал занимает ${A[jd_usage]}${A[jd_maxuse]:+, ограничение по размеру ${A[jd_maxuse]}}"); fi
    at="$(audit_num "${A[jd_oldest]:-}")"
    v="${A[jd_retention]:-}"
    if [[ -n "$v" && "$v" != "0" ]]; then
      audit_chk journald good "хранится не дольше $v" "$(audit_lines "${d[@]}")"
    else
      val="срок не ограничен"
      if (( at > 0 && now >= at )); then val+=": самая старая запись от $(audit_when "$at") ($(( (now - at) / 86400 )) дн.)"; fi
      audit_chk journald warn "$val" "$(audit_lines "${d[@]}")" \
        "Ограничь срок, например неделей: старые записи journald удалит сам. Совсем короткий журнал мешает разбираться в сбоях, неделя — середина. $where" \
        "mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\nMaxRetentionSec=7day\n' > /etc/systemd/journald.conf.d/iof.conf && systemctl restart systemd-journald"
    fi
  fi

  if (( ! hy2 )); then
    audit_chk hy2_log none "Hysteria2 на узле не установлена"
  else
    v="${A[hy2_log]:-info}"
    case "$v" in
      warn|error|fatal|panic|dpanic)
        audit_chk hy2_log good "уровень $v: адреса клиентов в журнал не пишутся" ;;
      *)
        val="уровень $v: в журнал пишется адрес каждого клиента"
        if [[ "$v" == "debug" ]]; then val+=" и адреса, куда он ходит"; fi
        audit_chk hy2_log warn "$val" "" \
          "С уровнем warn в журнале остаются предупреждения и ошибки. Служба перезапустится, клиенты переподключатся сами. $where" \
          "mkdir -p /etc/systemd/system/hysteria-server.service.d && printf '[Service]\nEnvironment=HYSTERIA_LOG_LEVEL=warn\n' > /etc/systemd/system/hysteria-server.service.d/iof-log.conf && systemctl daemon-reload && $restart" ;;
    esac
  fi

  s="${A[awg_c]:-}"
  if [[ -z "$s" ]]; then
    audit_chk awg_log none "AmneziaWG на узле не установлен"
  else
    val=""
    n="$(audit_num "${A[awg_log_size]:-}")"
    if (( n > 0 )); then val=", сейчас $(gb "$n" 1048576) МБ"; fi
    case "${A[awg_log_driver]:-}" in
      json-file)
        if [[ -n "${A[awg_log_max]:-}" ]]; then
          audit_chk awg_log good "ограничен: max-size ${A[awg_log_max]}$val"
        else
          audit_chk awg_log warn "json-file без ограничения размера$val" "" \
            "Ограничение задаётся при создании контейнера, приложение Amnezia его не ставит. Для новых контейнеров его можно задать в /etc/docker/daemon.json (log-opts max-size), а текущий лог обрезать командой ниже. $where" \
            "truncate -s 0 \"\$(docker inspect -f '{{.LogPath}}' $s)\""
        fi ;;
      local)    audit_chk awg_log good "драйвер local: размер ограничен, старое удаляется само$val" ;;
      none)     audit_chk awg_log good "лог контейнера выключен" ;;
      journald) audit_chk awg_log good "пишется в журнал systemd: срок хранения — в проверке «Срок хранения журнала»" ;;
      "")       audit_chk awg_log none "нет данных" ;;
      *)        audit_chk awg_log none "драйвер ${A[awg_log_driver]}, оценки для него нет" ;;
    esac
  fi

  # Время: синхронизация и расхождение с часами управляющего сервера сразу после ответа узла
  diff=0
  if [[ -n "${A[now_end]:-}" && -n "${A[x_now]:-}" ]]; then
    diff=$(( $(audit_num "${A[now_end]}") - $(audit_num "${A[x_now]}") ))
    if (( diff < 0 )); then diff=$(( -diff )); fi
  fi
  cmd="timedatectl set-ntp true && sleep 5 && timedatectl show -p NTPSynchronized"
  if (( diff > 60 )); then
    audit_chk time warn "часы узла расходятся с управляющим сервером на $diff с" "" \
      "Включи синхронизацию времени. Если она включена и здесь, и там, сверь часы обоих серверов. $where" "$cmd"
  elif [[ "${A[time_sync]:-}" == "yes" ]]; then
    audit_chk time good "синхронизировано"
  elif [[ "${A[time_sync]:-}" == "no" ]]; then
    val="не синхронизировано"
    if [[ "${A[time_ntp]:-}" == "no" ]]; then val+=", служба времени выключена"; fi
    audit_chk time warn "$val" "С управляющим сервером часы сейчас сходятся" \
      "Без синхронизации часы со временем уходят. В контейнере без своих часов это предупреждение можно оставить. $where" "$cmd"
  else
    audit_chk time none "нет данных (timedatectl не ответил)"
  fi
}

# Сбор фактов с узла для pmap по блокам из AUDIT_RUN. Вывод: строка "@<блок>", за ней факты блока.
# Для dpi к фактам узла добавляются проверки снаружи. Пользователь — тот, под которым iof заходит на узел
audit_job() {
  local out b user="root" target="${N_SSH[$1]}"
  if [[ "$target" == *@* ]]; then user="${target%%@*}"; fi
  for b in $AUDIT_RUN; do
    if [[ "$b" == "dpi" ]]; then
      out="$(run_on "$target" n_audit_dpi "$AUDIT_SALT")" || return $?
    else
      out="$(run_on "$target" n_audit_server "$user")" || return $?
    fi
    if ! grep -q '^now=' <<<"$out"; then
      echo "узел не ответил на аудит" >&2
      return 1
    fi
    printf '@%s\n%s\n' "$b" "$out"
    if [[ "$b" == "dpi" ]]; then
      echo "x_now=$(date +%s)"
      audit_outside "$1" "$out"
    fi
  done
}

# Факты блока $2 из вывода audit_job узла $1
audit_facts() { pm_out "$1" | awk -v b="@$2" '/^@/ { f = ($0 == b); next } f'; }

# Для AUDIT_PY после pmap audit_job: по каждому блоку строка R, затем на узел строка N (имя, адрес,
# 1 — ответил, время, ошибка) и строки C с его проверками
audit_results() {
  local i b now msg h
  now="$(date +%s)"
  for b in $AUDIT_RUN; do
    printf 'R\t%s\n' "$b"
    # Параметры AmneziaWG сравниваются между узлами этого запуска
    AUDIT_AWG=()
    if [[ "$b" == "dpi" ]]; then
      for i in "${SEL[@]}"; do
        pm_ok "$i" || continue
        h="$(audit_facts "$i" dpi | sed -n 's/^awg_hash=//p' | head -n 1)"
        if [[ -n "$h" ]]; then AUDIT_AWG["${N_NAME[$i]}"]="$h"; fi
      done
    fi
    for i in "${SEL[@]}"; do
      if pm_ok "$i"; then
        printf 'N\t%s\t%s\t1\t%s\t\n' "${N_NAME[$i]}" "${N_ADDR[$i]}" "$now"
        "audit_eval_$b" "$i" "$(audit_facts "$i" "$b")"
      else
        msg="$(pm_err "$i" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
        printf 'N\t%s\t%s\t0\t%s\t%s\n' "${N_NAME[$i]}" "${N_ADDR[$i]}" "$now" "${msg//$'\t'/ }"
      fi
    done
  done
}

# Для AUDIT_PY: все узлы из nodes.conf. По этому списку из результатов убираются удалённые узлы
audit_nodes() {
  local i
  for i in "${!N_NAME[@]}"; do
    printf 'L\t%s\t%s\t%s\n' "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(node_title "$i")"
  done
}

# Хранение и вывод результатов аудита. Режимы:
#  save <что проверяли: server, dpi или all> <папка> <сколько запусков хранить>  stdin: справочник,
#       узлы, результаты по блокам. Пишет <блок>.json каждого блока и одну строку в history.jsonl,
#       печатает проверки, которые стали хуже прошлого раза
#  api <папка>             stdin: справочник, узлы, настройки (строки S). Печатает JSON для панели
#  show <папка> <brief|full> <блоки через запятую> <узел>...  stdin: справочник. Печатает
#       последнюю проверку узлов
AUDIT_PY=$(cat <<'EOF'
import ipaddress, json, os, re, sys, time

RANK = {"none": 0, "good": 1, "warn": 2, "crit": 3}
WORD = {"none": "нет данных", "good": "в порядке", "warn": "внимание", "crit": "проблема"}
MARK = {"none": "--", "good": "ok", "warn": " !", "crit": "!!"}
COLOR = {"good": "32", "warn": "33", "crit": "31"}
for stream in (sys.stdin, sys.stdout):
    stream.reconfigure(encoding="utf-8", errors="replace")


def load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write(path, text):
    tmp = path + ".tmp"
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def history(base):
    out = []
    try:
        with open(os.path.join(base, "history.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def split(s):
    return [x for x in s.split("\x1f") if x]


def read_input():
    d = {"titles": {}, "groups": [], "catalog": [], "nodes": [], "settings": {}, "results": {}}
    cur, res = None, {}
    for raw in sys.stdin:
        f = raw.rstrip("\n").split("\t") + [""] * 8
        if f[0] == "B":
            d["titles"][f[1]] = f[2]
        elif f[0] == "R":
            cur, res = None, d["results"].setdefault(f[1], {})
        elif f[0] == "G":
            d["groups"].append({"block": f[1], "id": f[2], "title": f[3]})
        elif f[0] == "K":
            d["catalog"].append({"id": f[1], "block": f[2], "group": f[3], "title": f[4], "why": f[5]})
        elif f[0] == "L":
            d["nodes"].append({"name": f[1], "addr": f[2], "title": f[3]})
        elif f[0] == "S":
            d["settings"][f[1]] = f[2]
        elif f[0] == "N":
            cur = {"addr": f[2], "reachable": f[3] == "1", "at": int(f[4]), "error": f[5], "checks": []}
            res[f[1]] = cur
        elif f[0] == "C" and cur is not None:
            cur["checks"].append({"id": f[1], "status": f[2] if f[2] in RANK else "none", "value": f[3],
                                  "detail": split(f[4]), "hint": f[5], "cmd": "\n".join(split(f[6])),
                                  "act": f[7].split()})
    return d


def blocks(d):
    return list(dict.fromkeys(g["block"] for g in d["groups"]))


def save(label, base, keep):
    d = read_input()
    titles = {k["id"]: k["title"] for k in d["catalog"]}
    known = {n["name"] for n in d["nodes"]}
    counts, down, worse, seen = dict.fromkeys(RANK, 0), [], [], set()
    for block, results in d["results"].items():
        path = os.path.join(base, block + ".json")
        old = load(path, {}).get("nodes", {})
        nodes = {k: v for k, v in old.items() if k in known}
        for name, new in results.items():
            prev = old.get(name, {})
            seen.add(name)
            if not new["reachable"]:
                # Прошлые оценки остаются: с ними сравнится следующая удачная проверка
                new["checks"] = prev.get("checks", [])
                new["checked"] = prev.get("checked", 0)
                if name not in down:
                    down.append(name)
            else:
                new["checked"] = new["at"]
                was = {c["id"]: c["status"] for c in prev.get("checks", [])}
                for c in new["checks"]:
                    counts[c["status"]] += 1
                    # Первая проверка задаёт базу. Хуже — это внимание или проблема там, где было лучше
                    if c["id"] in was and RANK[c["status"]] > max(RANK.get(was[c["id"]], 0), 1):
                        worse.append({"node": name, "id": c["id"], "from": was[c["id"]], "to": c["status"]})
                        print(f'{name}: {titles.get(c["id"], c["id"])} — {c["value"]} '
                              f'(было: {WORD.get(was[c["id"]], was[c["id"]])})')
            nodes[name] = new
        write(path, json.dumps({"nodes": nodes}, ensure_ascii=False))
    # Одна строка на запуск, даже когда проверялись оба блока
    lines = [json.dumps(h, ensure_ascii=False) for h in history(base)]
    lines.append(json.dumps({"at": int(time.time()), "block": label, "nodes": len(seen),
                             "counts": counts, "down": down, "worse": worse}, ensure_ascii=False))
    write(os.path.join(base, "history.jsonl"), "\n".join(lines[-max(keep, 1):]) + "\n")


def api(base):
    d = read_input()
    known = [n["name"] for n in d["nodes"]]
    out = {"blocks": {}, "titles": d["titles"], "groups": d["groups"], "catalog": d["catalog"],
           "nodes": d["nodes"], "history": history(base),
           "settings": {"cron": d["settings"].get("cron", ""), "tg": d["settings"].get("tg") == "yes",
                        "hop": d["settings"].get("hop", ""), "block_cron": d["settings"].get("block_cron", ""),
                        "blocklist": d["settings"].get("blocklist") == "yes"}}
    for b in blocks(d):
        saved = load(os.path.join(base, b + ".json"), {}).get("nodes", {})
        out["blocks"][b] = {"nodes": {k: saved[k] for k in known if k in saved}}
    out["probe"] = probe_api(os.path.join(base, "probe"))
    json.dump(out, sys.stdout, ensure_ascii=False)
    print()


def show(base, mode, want, names):
    d = read_input()
    color = os.environ.get("IOF_COLOR") == "1"
    brief = mode == "brief"

    def paint(st, text):
        return f"\033[{COLOR[st]}m{text}\033[0m" if color and st in COLOR else text

    for b in blocks(d):
        if b not in want:
            continue
        saved = load(os.path.join(base, b + ".json"), {}).get("nodes", {})
        title = d["titles"].get(b, b)
        for name in names:
            node = saved.get(name)
            if node is None:
                print(f"== {name} · {title}: проверки ещё не было")
                continue
            when = time.strftime("%d.%m.%Y %H:%M", time.localtime(node["at"]))
            head = f"== {name} ({node['addr']}) · {title}, {when}: "
            if not node["reachable"]:
                print(head + paint("crit", f"нет связи ({node['error'] or 'нет связи по SSH'})"))
                continue
            by = {c["id"]: c for c in node["checks"]}
            n = {st: sum(1 for c in node["checks"] if c["status"] == st) for st in RANK}
            print(head + f"проблем {n['crit']}, внимание {n['warn']}, в порядке {n['good']}, нет данных {n['none']}")
            for g in d["groups"]:
                if g["block"] != b:
                    continue
                rows = [(k, by[k["id"]]) for k in d["catalog"]
                        if k["block"] == b and k["group"] == g["id"] and k["id"] in by]
                if brief:
                    rows = [r for r in rows if r[1]["status"] in ("warn", "crit")]
                if rows and not brief:
                    print(f"  {g['title']}")
                for k, c in rows:
                    print(f"  {paint(c['status'], MARK[c['status']])} {k['title']}: {c['value']}")
                    if brief:
                        continue
                    for line in c["detail"]:
                        print(f"       {line}")
                    if c["status"] in ("warn", "crit") and (c["hint"] or c["cmd"]):
                        print(f"       Как исправить: {c['hint']}")
                        for line in c["cmd"].splitlines():
                            print(f"         {line}")


# Проверка с ПК (iof audit probe). Сессия: session.json, токен мишеней отдельно в token. Отчёт
# probe.ps1 приходит сырым, вердикт по слоям считается здесь: ПК сравнивается с контролем,
# который управляющий сервер прошёл до тех же мишеней сразу после запуска. crit только при
# высокой уверенности: контроль прошёл, у ПК есть интернет, VPN не видно, попытки сходятся

FULL = 262144
LAYERS = [("icmp", "Ping"), ("tcp", "TCP"), ("tls", "TLS"), ("data", "Данные 256 КБ"), ("udp", "UDP"),
          ("quic", "UDP, похожий на QUIC"), ("hy2", "Порт Hysteria2"), ("tunnel", "Туннель Hysteria2")]
CONF = {"low": 0, "medium": 1, "high": 2}
CONF_WORD = {"high": "высокая", "medium": "средняя", "low": "низкая"}
# Почему мишень на узле не запущена: текст и команда
NOT_STARTED = {
    "nopython": ("нет python3, он нужен мишени", "apt install python3"),
    "noopenssl": ("нет openssl для сертификата мишени", "apt install openssl"),
    "nosystemd": ("нет systemd-run, мишень не запустить", ""),
    "nft": ("входящие режет своя таблица nftables, а правило для мишени iof ставит только через iptables", ""),
    "busy": ("нет свободного порта для мишени", ""),
    "error": ("мишень не запустилась", ""),
    "down": ("узел не ответил по SSH", ""),
}
TUNNEL_SKIP = {"nohysteria": "нет hysteria.exe", "nolinks": "в буфере обмена нет ссылок hy2://",
               "nolink": "в буфере обмена нет ссылки на этот узел", "declined": "отказ на ПК"}
HY2_WORD = {"vn": "отвечает как QUIC", "silent": "молчит", "closed": "порт закрыт", "reply": "ответ не как у QUIC",
            "error": "ошибка проверки"}


def fail(text):
    print("Ошибка: " + text, file=sys.stderr)
    sys.exit(2)


def num(v, hi):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0
    return int(v) if 0 <= v <= hi else 0


def txt(v, n):
    return "".join(ch for ch in v if ch.isprintable())[:n] if isinstance(v, str) else ""


def obj(v):
    return v if isinstance(v, dict) else {}


def mid(values):
    values = sorted(values)
    return values[len(values) // 2] if values else 0


def private(ip):
    try:
        return not ipaddress.ip_address(ip).is_global
    except ValueError:
        return False


def side(t):
    """Сырые слои одной стороны, ПК или контроля -> счётчики по слоям."""
    t = obj(t)
    conn = [c for c in t.get("conn") if isinstance(c, dict)][:5] if isinstance(t.get("conn"), list) else []
    tcp = [c for c in conn if c.get("tcp") is not None]
    tls = [c for c in tcp if c.get("tls") is not None]
    size = [num(c.get("bytes"), FULL) for c in tls]
    icmp, u, q = obj(t.get("icmp")), obj(t.get("udp")), obj(t.get("quic"))
    return {
        "n": len(conn),
        "icmp": (num(icmp.get("got"), 10), num(icmp.get("sent"), 10), num(icmp.get("ms"), 60000)),
        "tcp": (len(tcp), mid([num(c.get("tcp"), 60000) for c in tcp])),
        "tls": (len(tls), mid([num(c.get("tls"), 60000) for c in tls])),
        "mitm": any(c.get("fp") == "mismatch" for c in tls),
        "full": size.count(FULL),
        "stall": [b for b in size if 0 < b < FULL],
        "data_ms": mid([num(c.get("ms"), 120000) for c, b in zip(tls, size) if b == FULL]),
        "errs": [txt(c.get("err"), 60) for c in conn if c.get("err")],
        "src": [txt(c.get("src"), 45) for c in conn if c.get("src")],
        "udp": (num(u.get("got"), 50), num(u.get("sent"), 50)),
        "quic": (num(q.get("got"), 50), num(q.get("sent"), 50)),
        "hy2": txt(t.get("hy2"), 10),
        "tunnel": obj(t.get("tunnel")),
    }


def tries(ok, n, ms=0, errs=()):
    if not n:
        return "не проверялся"
    s = f"{ok} из {n}" + (f", {ms} мс" if ok and ms else "")
    if ok < n and errs:
        s += f" ({errs[0]})"
    return s


def check_line(s):
    """Короткий итог одной стороны для сессии и консоли."""
    parts = []
    if s["icmp"][1]:
        parts.append(f"ping {s['icmp'][0]}/{s['icmp'][1]}")
    if s["n"]:
        parts += [f"TCP {s['tcp'][0]}/{s['n']}", f"TLS {s['tls'][0]}/{s['n']}", f"данные {s['full']}/{s['n']}"]
    for k, title in (("udp", "UDP"), ("quic", "QUIC")):
        if s[k][1]:
            parts.append(f"{title} {s[k][0]}/{s[k][1]}")
    if s["hy2"]:
        parts.append("Hysteria2 " + HY2_WORD.get(s["hy2"], s["hy2"]))
    return " · ".join(parts) or "нет данных"


def verdicts(pc, ctl, hy2_port):
    """Слои узла: [(id, вердикт, с ПК, контроль, пояснение)]. Вердикты: ok, blocked, stall, partial,
    mitm, fail, down (контроль тоже не прошёл), unknown (не с чем сравнить), skipped."""
    rows = []
    got, sent, m = pc["icmp"]
    cg, cs, cm = ctl["icmp"]
    v = ("skipped" if not sent else "unknown" if not cs and not got else "down" if cs and not cg
         else "ok" if got == sent else "partial" if got else "blocked")
    rows.append(("icmp", v, tries(got, sent, m), tries(cg, cs, cm) if cs else "нет ping на управляющем сервере",
                 "ICMP по дороге режут часто, на VPN это не влияет" if v in ("blocked", "partial") else ""))

    n, cn = pc["n"], ctl["n"]
    ok, cok = pc["tcp"][0], ctl["tcp"][0]
    v = "skipped" if not n else "down" if not cok else "blocked" if not ok else "partial" if ok < n else "ok"
    rows.append(("tcp", v, tries(ok, n, pc["tcp"][1], pc["errs"]), tries(cok, cn, ctl["tcp"][1], ctl["errs"]), ""))

    t, ct = pc["tls"][0], ctl["tls"][0]
    pct = tries(t, ok, pc["tls"][1], [e for e in pc["errs"] if e.startswith("tls")])
    if pc["mitm"]:
        pct += ", сертификат подменён"
    v = ("skipped" if not ok else "down" if not ct else "mitm" if pc["mitm"] else "blocked" if not t
         else "partial" if t < ok else "ok")
    rows.append(("tls", v, pct if ok else "не дошло до TLS", tries(ct, cok, ctl["tls"][1]), ""))

    full, stall = pc["full"], pc["stall"]
    note, pct = "", f"{full} из {t}" + (f", {pc['data_ms']} мс" if full else "")
    if stall:
        kb = mid(stall) // 1024
        pct += f"; встаёт на {kb} КБ ({len(stall)} из {t})"
        if 8 <= kb <= 40 and not full:
            note = "Похоже на ограничение ТСПУ: соединения с зарубежными хостингами встают после 15–20 КБ"
    v = ("skipped" if not t else "down" if not ctl["full"] else "ok" if full == t
         else "stall" if not full and stall else "blocked" if not full else "partial")
    rows.append(("data", v, pct if t else "не дошло до данных", f"{ctl['full']} из {ct}", note))

    for k in ("udp", "quic"):
        (g, s), (cg, cs) = pc[k], ctl[k]
        v = "skipped" if not s else "down" if not cg else "blocked" if not g else "partial" if g < s - 1 else "ok"
        note = ""
        if k == "quic" and v == "blocked" and rows[-1][1] == "ok":
            note = "Обычный UDP проходит, а пакеты, похожие на QUIC, — нет"
        rows.append((k, v, tries(g, s), tries(cg, cs), note))

    p, c = pc["hy2"], ctl["hy2"]
    if not hy2_port:
        rows.append(("hy2", "skipped", "Hysteria2 на узле нет", "—", ""))
    elif not p:
        rows.append(("hy2", "skipped", "не проверялся", HY2_WORD.get(c, c or "—"), ""))
    elif c != "vn":
        rows.append(("hy2", "down", HY2_WORD.get(p, p), HY2_WORD.get(c, c or "—"),
                     "Управляющему серверу порт тоже не ответил согласованием версий. Так выглядит Salamander: тогда "
                     "Hysteria2 проверяет только туннель"))
    else:
        rows.append(("hy2", "ok" if p == "vn" else "blocked", HY2_WORD.get(p, p), HY2_WORD["vn"], ""))

    tn = pc["tunnel"]
    if tn.get("tested") is not True:
        why = txt(tn.get("reason"), 20)
        rows.append(("tunnel", "skipped", "не проверялся: " + TUNNEL_SKIP.get(why, why or "нет данных"), "—", ""))
    elif tn.get("ok") is True:
        rows.append(("tunnel", "ok", "работает" + (f", {num(tn.get('ms'), 120000)} мс" if tn.get("ms") else ""), "—", ""))
    else:
        rows.append(("tunnel", "fail", "не поднялся: " + (txt(tn.get("err"), 120) or "нет ответа"), "—", ""))
    return rows


def layer_status(lid, v, conf):
    if conf == "low" or v in ("down", "unknown", "skipped"):
        return "none"
    if v == "ok":
        return "good"
    if lid == "icmp":
        return "none"
    return "crit" if v in ("blocked", "stall") and conf == "high" else "warn"


def node_result(name, n, rep_t, conf):
    """Итог узла: статус, уверенность, значение, совет и слои."""
    state = n.get("state", "")
    if state != "started":
        text, cmd = NOT_STARTED.get(state, ("мишень не запустилась", ""))
        err = txt(n.get("error"), 120)
        return {"addr": n.get("addr", ""), "status": "none", "confidence": conf, "value": "не проверялся: " + text,
                "detail": [err] if err and state not in ("nopython", "noopenssl") else [], "hint": "", "cmd": cmd, "layers": []}
    if rep_t is None:
        return {"addr": n.get("addr", ""), "status": "none", "confidence": conf, "value": "скрипт на ПК этот узел не проверил",
                "detail": [], "hint": "", "cmd": "", "layers": []}
    pc, ctl = side(rep_t), side(n.get("control"))
    lc = conf if pc["n"] >= 3 or conf == "low" else "medium"
    rows = []
    for lid, v, pct, ctt, note in verdicts(pc, ctl, n.get("hy2_port")):
        rows.append({"id": lid, "title": dict(LAYERS)[lid], "verdict": v, "status": layer_status(lid, v, lc),
                     "pc": pct, "control": ctt, "note": note})
    by = {r["id"]: r for r in rows}
    st = max((r["status"] for r in rows), key=lambda s: RANK[s])
    core = [r for r in rows if r["id"] not in ("icmp", "tunnel")]
    parts, hint, detail = [], [], []
    if n.get("local"):
        detail.append("Контроль шёл с самого управляющего сервера: это не взгляд снаружи")
    if all(r["verdict"] in ("down", "skipped") for r in core):
        parts.append("мишень не ответила и управляющему серверу")
        hint.append("Порт мишени закрыт у хостера (security group) или файрволом по пути. Задай в /root/iof/iof.env "
                    "PROBE_PORTS диапазоном, открытым у хостера, и повтори.")
    blocked = [r["title"] for r in rows if r["verdict"] == "blocked" and r["id"] != "icmp"]
    if blocked:
        parts.append("с ПК не проходят: " + ", ".join(blocked))
    if by["data"]["verdict"] == "stall":
        parts.append("данные встают на " + by["data"]["pc"].rsplit("встаёт на ", 1)[-1].split(" (")[0])
        hint.append("TLS-соединение с адресом встаёт после первых килобайт: так ТСПУ ограничивает соединения с зарубежными "
                    "хостингами. Hysteria2 и AmneziaWG работают по UDP, их это не задевает: смотри строки UDP и Hysteria2.")
    partial = [r["title"] for r in rows if r["verdict"] == "partial" and r["id"] != "icmp"]
    if partial:
        parts.append("с ПК проходят не все попытки: " + ", ".join(partial))
    if by["tls"]["verdict"] == "mitm":
        parts.append("сертификат мишени подменён по дороге")
        hint.append("Так делают антивирусы с проверкой защищённых соединений (например Kaspersky), корпоративные прокси или "
                    "провайдер. Выключи проверку HTTPS в антивирусе и повтори.")
    if by["tunnel"]["verdict"] == "fail":
        parts.append("туннель Hysteria2 не поднялся")
        hint.append("Клиент Hysteria2 на ПК не поднял туннель по ссылке группы: проверь, что ссылка свежая (sudo iof hy2 show) "
                    "и hysteria.exe новой версии.")
    if "UDP, похожий на QUIC" in blocked and "UDP" not in blocked:
        hint.append("Похожие на QUIC пакеты режутся, обычный UDP проходит. Hysteria2 без Salamander выглядит как QUIC: "
                    "Salamander это прячет, см. «Режим маскировки» в блоке «Защита от РКН».")
    elif "Порт Hysteria2" in blocked:
        hint.append("Порт Hysteria2 с ПК не отвечает, хотя отвечает управляющему серверу: его режут по дороге. "
                    "Варианты — другой порт или смена портов (port hopping), см. блок «Защита от РКН».")
    if "TCP" in blocked and "UDP" in blocked:
        hint.append("С ПК не доходит ничего: похоже, адрес узла заблокирован целиком. Проверь из другой сети (мобильный "
                    "интернет): если так везде, помогает только новый адрес у хостера или другой узел.")
    if not parts:
        quiet = all(r["verdict"] in ("ok", "skipped", "unknown") for r in rows)
        parts.append("с ПК проходят все проверенные слои" if quiet else "сравнить не с чем")
    for r in rows:
        if r["note"] and r["status"] in ("warn", "crit"):
            detail.append(r["note"])
    return {"addr": n.get("addr", ""), "status": st, "confidence": lc, "value": "; ".join(parts), "detail": detail,
            "hint": " ".join(hint) if st in ("warn", "crit") else "", "cmd": "", "layers": rows}


def report_confidence(rep, sess, srcs, who):
    """Уверенность во всём отчёте и почему она такая. Возвращает (уверенность, причины, сеть ПК)."""
    conf, reasons = "high", []

    def lower(to, why):
        nonlocal conf
        if CONF[to] < CONF[conf]:
            conf = to
        reasons.append(why)

    ips = {}
    for name, n in sess["nodes"].items():
        for a in (n.get("ip"), n.get("addr")):
            if a:
                ips[a] = name
    src = max(set(srcs), key=srcs.count) if srcs else ""
    remap = rep.get("remap") is True
    net = {"label": "не определена", "ip": "", "vpn": "no", "remap": remap}
    if src:
        net["ip"] = re.sub(r"\.\d+$", ".0/24", src) if re.match(r"^\d+\.\d+\.\d+\.\d+$", src) else src
    if src in ips:
        net["vpn"] = "yes"
        lower("low", f"IP источника — адрес узла {ips[src]}: проверка шла через VPN на этот узел. Выключи VPN на ПК и повтори")
    elif src and private(src) and not remap:
        net["vpn"] = "yes"
        lower("low", "IP источника частный: ПК ходил к узлам через VPN или из одной с ними сети")
    elif not src:
        reasons.append("IP источника неизвестен: ни одна попытка не дошла до данных")
    if remap:
        reasons.append("Адреса узлов подменены IOF_PROBE_MAP: это стенд, путь до узлов идёт не через провайдера")
    w = who.split("|")
    if w[0] == "ok":
        net["label"] = " ".join(x for x in (w[1], w[2]) if x) + (f" ({w[3]})" if w[3] else "") or "не определена"
        if w[3] and w[3] != "RU":
            net["vpn"] = "suspect" if net["vpn"] == "no" else net["vpn"]
            lower("medium", f"По whois сеть ПК не российская ({w[3]}): провайдер другой страны или VPN")
    elif w[0] == "private":
        net["label"] = "частный адрес"
    client = obj(rep.get("client"))
    vpn = [txt(x, 80) for x in client.get("vpn") or [] if isinstance(x, str)][:5] if isinstance(client.get("vpn"), list) else []
    if vpn:
        if net["vpn"] == "no":
            net["vpn"] = "suspect"
        lower("medium", "На ПК включён адаптер " + ", ".join(vpn) + ": если это VPN в режиме TUN, трафик шёл через него")
    if client.get("proxy") in ("manual", "pac"):
        reasons.append("В системе задан прокси. На проверку он не влияет: скрипт ходит напрямую")
    lists = [x for x in rep.get("lists") or [] if isinstance(x, dict)] if isinstance(rep.get("lists"), list) else []
    white = [x for x in lists if x.get("list") == "white"]
    black = [x for x in lists if x.get("list") == "black"]
    wok, bok = sum(x.get("ok") is True for x in white), sum(x.get("ok") is True for x in black)
    internet = "unknown" if not white else "ok" if wok == len(white) else "fail" if not wok else "partial"
    filtering = "unknown" if not black else "yes" if not bok else "no" if bok == len(black) else "partial"
    if internet == "fail":
        lower("low", "Не открылся ни один сайт из probe-white.txt: у ПК нет интернета или его режут")
    elif internet == "partial":
        lower("medium", "Открылись не все сайты из probe-white.txt")
    if filtering == "no":
        lower("medium", "Сайты из probe-black.txt открываются: провайдер их не блокирует или трафик идёт в обход (VPN, прокси)")
    elif filtering == "partial":
        reasons.append("Часть сайтов из probe-black.txt открывается")
    return conf, reasons, net, internet, filtering, lists


def read_session(base):
    sess = load(os.path.join(base, "session.json"), None)
    return sess if isinstance(sess, dict) and isinstance(sess.get("nodes"), dict) else None


def probe_session(base):
    sess = {"id": "", "started": 0, "expires": 0, "ttl": 0, "stopped": 0, "lists": {"white": [], "black": []}, "nodes": {}}
    cur = None
    for raw in sys.stdin:
        f = raw.rstrip("\n").split("\t") + [""] * 6
        if f[0] == "P":
            sess.update(id=f[1], started=int(f[2]), ttl=int(f[3]), expires=int(f[2]) + int(f[3]))
        elif f[0] in ("W", "X"):
            sess["lists"]["white" if f[0] == "W" else "black"].append(f[1])
        elif f[0] == "N":
            cur = {"addr": f[2], "local": f[4] == "1", "state": "" if f[3] == "1" else "down", "error": f[5][:200],
                   "ip": "", "port": 0, "fp": "", "hy2_port": 0, "fw": "", "control": None}
            sess["nodes"][f[1]] = cur
        elif f[0] == "F" and cur is not None:
            k, _, v = f[1].partition("=")
            if k == "probe":
                cur["state"] = v
            elif k in ("port", "hy2_port"):
                cur[k] = int(v) if v.isdigit() else 0
            elif k in ("fp", "fw", "ip", "error"):
                cur[k] = v[:200]
            elif k == "trace":
                try:
                    cur["control"] = json.loads(v)
                except ValueError:
                    cur["control"] = {}
    for n in sess["nodes"].values():
        n["state"] = n["state"] or "error"
        n["check"] = check_line(side(n["control"])) if n["state"] == "started" else ""
    started = any(n["state"] == "started" for n in sess["nodes"].values())
    if started:
        write(os.path.join(base, "session.json"), json.dumps(sess, ensure_ascii=False))
    for name, n in sess["nodes"].items():
        if n["state"] == "started":
            print(f"  {name:<20} порт {n['port']:<6} контроль: {n['check']}")
        else:
            text, cmd = NOT_STARTED.get(n["state"], ("мишень не запустилась", ""))
            print(f"  {name:<20} не проверяется: {text}" + (f" ({n['error']})" if n["error"] and not cmd else "")
                  + (f". Исправить на узле: {cmd}" if cmd else ""))
    if not started:
        sys.exit(3)


def probe_stop(base):
    sess = read_session(base)
    if sess and not sess.get("stopped"):
        sess["stopped"] = int(time.time())
        write(os.path.join(base, "session.json"), json.dumps(sess, ensure_ascii=False))


def probe_nodes(base):
    sess = read_session(base)
    if sess:
        print(sess["id"], sess["expires"], sess.get("stopped", 0))
        for name in sess["nodes"]:
            print(name)


def report_srcs(rep):
    out = []
    for t in rep.get("targets") or []:
        if isinstance(t, dict):
            out += side(t)["src"]
    return [s for s in out if re.match(r"^[0-9a-fA-F.:]+$", s)]


def load_report(path, sess, token):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        fail("отчёт не прочитать")
    if token and token.encode() in raw:
        fail("в отчёте есть токен мишеней, такой отчёт не принимаю")
    try:
        rep = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError):
        fail("отчёт не JSON")
    if not isinstance(rep, dict) or rep.get("v") != 1:
        fail("это не отчёт probe.ps1")
    if sess is not None and rep.get("session") != sess["id"]:
        fail(f"отчёт от другой проверки ({txt(rep.get('session'), 20) or 'без номера'}), сейчас {sess['id']}")
    return rep


def probe_src(path):
    srcs = report_srcs(load_report(path, None, ""))
    if srcs:
        print(max(set(srcs), key=srcs.count))


def results(base):
    if not os.path.isdir(base):
        return []
    names = [f for f in os.listdir(base) if re.fullmatch(r"\d{8}-\d{6}(-\d+)?\.json", f)]
    # В одну секунду первый отчёт без суффикса, остальные — -2, -3, ... -10.
    return sorted(names, key=lambda f: (f[:15], int(f[16:-5] or 1)))


def probe_import(base, keep, path):
    sess = read_session(base)
    if sess is None:
        fail("нет сессии проверки с ПК: сначала sudo iof audit probe start")
    try:
        with open(os.path.join(base, "token"), encoding="utf-8") as f:
            token = f.read().strip()
    except OSError:
        token = ""
    rep = load_report(path, sess, token)
    who = ""
    for raw in sys.stdin:
        f = raw.rstrip("\n").split("\t") + [""]
        if f[0] == "W":
            who = f[1]
    by = {}
    for t in rep.get("targets") or []:
        if isinstance(t, dict) and t.get("node") in sess["nodes"] and t["node"] not in by:
            by[t["node"]] = t
    conf, reasons, net, internet, filtering, lists = report_confidence(rep, sess, report_srcs(rep), who)
    client = obj(rep.get("client"))
    out = {"at": int(time.time()), "session": sess["id"], "started": sess["started"], "confidence": conf,
           "reasons": reasons, "net": net, "internet": internet, "filtering": filtering,
           "client": {"os": txt(client.get("os"), 60), "proxy": txt(client.get("proxy"), 10)},
           "lists": [{"host": txt(x.get("host"), 80), "list": x.get("list"), "ok": x.get("ok") is True,
                      "err": txt(x.get("err"), 60)} for x in lists][:40],
           "nodes": {}, "counts": dict.fromkeys(RANK, 0)}
    for name, n in sess["nodes"].items():
        r = node_result(name, n, by.get(name), conf)
        out["nodes"][name] = r
        out["counts"][r["status"]] += 1
    os.makedirs(base, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(out["at"]))
    # После удаления старых отчётов не используем их номера повторно.
    i = max((int(f[16:-5] or 1) for f in results(base) if f[:15] == stamp), default=0) + 1
    name = f"{stamp}-{i}.json" if i > 1 else stamp + ".json"
    write(os.path.join(base, name), json.dumps(out, ensure_ascii=False))
    for old in results(base)[:-max(keep, 1)]:
        os.remove(os.path.join(base, old))
    print_result(out, False)


def print_result(r, full):
    color = os.environ.get("IOF_COLOR") == "1"

    def paint(st, text):
        return f"\033[{COLOR[st]}m{text}\033[0m" if color and st in COLOR else text

    when = time.strftime("%d.%m.%Y %H:%M", time.localtime(r["at"]))
    print(f"Проверка с ПК {r['session']} от {when}: сеть ПК {r['net']['label']}, уверенность {CONF_WORD[r['confidence']]}")
    for why in r["reasons"]:
        print(f"     {why}")
    for name, n in r["nodes"].items():
        print(f"  {paint(n['status'], MARK[n['status']])} {name}: {n['value']}")
        if not full:
            continue
        for line in n["detail"]:
            print(f"       {line}")
        for x in n["layers"]:
            print(f"       {paint(x['status'], MARK[x['status']])} {x['title']}: с ПК {x['pc']}; контроль {x['control']}")
        if n["hint"]:
            print(f"       Что делать: {n['hint']}")
        if n["cmd"]:
            print(f"       Исправить на узле: {n['cmd']}")


def probe_list(base):
    names = results(base)
    if not names:
        print("Проверок с ПК ещё не было: sudo iof audit probe start, затем страница «Безопасность» панели")
        return
    print_result(load(os.path.join(base, names[-1]), {}), True)
    if len(names) > 1:
        print("\nРаньше:")
        for name in reversed(names[:-1]):
            r = load(os.path.join(base, name), {})
            if r:
                c = r["counts"]
                print(f"  {time.strftime('%d.%m.%Y %H:%M', time.localtime(r['at']))}  {r['net']['label']}, "
                      f"уверенность {CONF_WORD[r['confidence']]}: проблем {c['crit']}, внимание {c['warn']}, "
                      f"в порядке {c['good']}, нет данных {c['none']}")


def probe_api(base):
    """Раздел probe для iof api audit: сессия без токена и контроля, последний результат, история."""
    sess, names = read_session(base), results(base)
    pub = None
    if sess:
        pub = {k: sess.get(k) for k in ("id", "started", "expires", "stopped")}
        pub["nodes"] = {name: {k: n.get(k) for k in ("addr", "state", "port", "fw", "error", "local", "check")}
                        for name, n in sess["nodes"].items()}
    hist = []
    for name in names:
        r = load(os.path.join(base, name), {})
        if r:
            hist.append({"at": r["at"], "session": r["session"], "confidence": r["confidence"],
                         "net": r["net"]["label"], "counts": r["counts"]})
    last = load(os.path.join(base, names[-1]), None) if names else None
    return {"session": pub, "last": last, "history": hist}


mode = sys.argv[1]
if mode == "save":
    save(sys.argv[2], sys.argv[3], int(sys.argv[4]))
elif mode == "api":
    api(sys.argv[2])
elif mode == "probe-session":
    probe_session(sys.argv[2])
elif mode == "probe-nodes":
    probe_nodes(sys.argv[2])
elif mode == "probe-stop":
    probe_stop(sys.argv[2])
elif mode == "probe-src":
    probe_src(sys.argv[2])
elif mode == "probe-import":
    probe_import(sys.argv[2], int(sys.argv[3]), sys.argv[4])
elif mode == "probe-list":
    probe_list(sys.argv[2])
else:
    show(sys.argv[2], sys.argv[3], sys.argv[4].split(","), sys.argv[5:])
EOF
)

audit_py() {
  local color=0
  if [[ -t 1 ]]; then color=1; fi
  IOF_COLOR="$color" python3 -c "$AUDIT_PY" "$@"
}

audit_need_python() {
  have python3 || die "iof audit хранит результат в JSON, для этого нужен python3: apt install python3"
}

# Проверка выбранных узлов (-n): блок server, dpi или оба (all, так по умолчанию). В AUDIT_WORSE
# остаются проверки, которые стали хуже прошлого раза
AUDIT_WORSE=""
audit_run() {
  local block="${1:-all}" i failed=() names=()
  case "$block" in
    server|dpi) AUDIT_RUN="$block" ;;
    all)        AUDIT_RUN="server dpi" ;;
    *)          die "используй: iof audit run [server|dpi|all]" ;;
  esac
  audit_need_python
  read_nodes
  read_relays
  select_nodes
  mkdir -p "$AUDIT_DIR"
  chmod 700 "$AUDIT_DIR"
  if [[ "$AUDIT_RUN" == *dpi* ]]; then audit_dpi_prepare; fi
  echo "Проверяю узлы: ${#SEL[@]}, одновременно до $PARALLEL"
  pmap audit_job "${SEL[@]}"
  AUDIT_WORSE="$({ audit_catalog; audit_nodes; audit_results; } | audit_py save "$block" "$AUDIT_DIR" "$AUDIT_KEEP")" \
    || die "не удалось сохранить результат аудита в $AUDIT_DIR"
  for i in "${SEL[@]}"; do
    names+=("${N_NAME[$i]}")
    pm_ok "$i" || failed+=("$i")
  done
  echo
  audit_catalog | audit_py show "$AUDIT_DIR" brief "${AUDIT_RUN// /,}" "${names[@]}"
  if (( ${#failed[@]} > 0 )); then
    echo
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
  fi
  echo
  echo "Подробно и как исправить: sudo iof audit show [узел], в панели — страница «Безопасность»"
}

# Последняя проверка без опроса узлов: все проверки узла, подробности и как исправить
audit_show() {
  local i names=()
  audit_need_python
  [[ -f "$AUDIT_DIR/server.json" || -f "$AUDIT_DIR/dpi.json" ]] || die "проверок ещё не было, сначала: sudo iof audit run"
  read_nodes
  select_nodes "$@"
  for i in "${SEL[@]}"; do names+=("${N_NAME[$i]}"); done
  audit_catalog | audit_py show "$AUDIT_DIR" full server,dpi "${names[@]}"
}

# Для cron раз в сутки: проверка всех узлов и одно сообщение в Telegram, если что-то стало хуже.
# О потере связи с узлом сообщает iof check, здесь это ухудшением не считается
audit_cron() {
  local total
  audit_run all >/dev/null
  if [[ -z "$AUDIT_WORSE" ]]; then return 0; fi
  echo "$AUDIT_WORSE"
  total="$(grep -c . <<<"$AUDIT_WORSE")"
  if (( total > 25 )); then
    AUDIT_WORSE="$(head -n 25 <<<"$AUDIT_WORSE")"$'\n'"… и ещё $((total - 25))"
  fi
  tg_send audit "$AUDIT_WORSE"$'\n'"Подробно: sudo iof audit show или страница «Безопасность» панели"
}

cmd_audit() {
  local action="${1:-}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    run)   audit_run "$@" ;;
    show)  audit_show "$@" ;;
    cron)  audit_cron ;;
    probe) audit_probe "$@" ;;
    *)     die "используй: iof audit run [server|dpi|all] | show [узел] | cron | probe start|stop|import|list" ;;
  esac
}
