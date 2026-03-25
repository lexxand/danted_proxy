# danted_proxy
Настройка прокси сервера

Ставим прокси сервер

```
sudo apt install dante-server
```

Создаем пользователя без возможности работать в командной строке
```
sudo useradd -M -s /usr/sbin/nologin pruser
```

Задаем пароль пользоватея
```
sudo passwd pruser
```

Правим конфиг
```
sudo nano /etc/danted.conf
```

Вставляем это в конфиг (если надо, меняем конфиг)

```
logoutput: syslog
user.privileged: root
user.unprivileged: nobody
# Интерфейс и порт для прослушивания
internal: 0.0.0.0 port=15097
external: eth0
# Методы аутентификации
socksmethod: username
clientmethod: none
# Правила доступа
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: error connect disconnect
    socksmethod: username
}





```

Рестартуем и делаем доступным после перезагрузки

```
sudo systemctl restart danted
sudo systemctl enable danted
sudo systemctl status danted

```
