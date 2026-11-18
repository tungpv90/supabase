# Deploy supabase.apaxsoft.com

Mỗi lần push lên nhánh `master` của repo `tungpv90/supabase`, GitHub Actions build Studio, đẩy image lên GHCR và cập nhật bộ Supabase self-host trên server `62.84.190.239`, truy cập tại `https://supabase.apaxsoft.com`.

## Tổng quan

Đường đi của một yêu cầu từ trình duyệt:

1. Trình duyệt gọi `https://supabase.apaxsoft.com` (cổng 443).
2. nginx của aaPanel trên server nhận yêu cầu, xử lý HTTPS rồi chuyển tiếp vào `127.0.0.1:18000`.
3. Gateway Envoy của Supabase nhận ở cổng `18000`, kiểm tra mật khẩu dashboard và chuyển đến đúng service (Studio, Auth, REST, Realtime, Storage, Edge Functions).
4. Các service chạy trong Docker Compose tại `/opt/supabase`. Dữ liệu Postgres nằm ở `/opt/supabase/volumes/db/data`.

Các file liên quan trong repo:

| File                                     | Việc nó làm                                                              |
| ---------------------------------------- | ------------------------------------------------------------------------ |
| `.github/workflows/deploy-apaxsoft.yml`  | Workflow: build image, đồng bộ file, chạy deploy, kiểm tra               |
| `deploy/apaxsoft/remote-deploy.sh`       | Script chạy trên server: tạo `.env` lần đầu, pull image, khởi động stack |
| `docker/docker-compose.studio-image.yml` | Ghi đè image Studio bằng image tự build                                  |

Server này còn chạy các trang khác qua nginx của aaPanel, vì vậy Supabase không được chiếm cổng 80 và 443.

## Bước 1: Chuẩn bị server (làm một lần)

Server cần Docker, Docker Compose, rsync, openssl và ít nhất 4 GB RAM.

1. Mở PowerShell trên Windows và đăng nhập: `ssh root@62.84.190.239`. Khi dòng lệnh đổi thành `root@...#` nghĩa là bạn đang ở trong server. Các lệnh chỉ dành cho Windows (`Get-Content`, `Set-Clipboard`) sẽ không chạy ở đó. Gõ `exit` để quay về Windows.
2. Cài công cụ: `apt-get update && apt-get install -y rsync curl openssl ca-certificates`
3. Cài Docker: `curl -fsSL https://get.docker.com | sh`
4. Kiểm tra: `docker --version` và `docker compose version` phải in ra phiên bản.
5. Kiểm tra RAM bằng `free -h`. Nếu dưới 4 GB, tạo swap: `fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab`
6. Mở cổng 22, 80, 443 trên firewall của nhà cung cấp server (và trong aaPanel, mục Security, nếu đang dùng).

## Bước 2: Trỏ DNS về server

`supabase.apaxsoft.com` phải trỏ thẳng về `62.84.190.239`, không đi qua proxy của Cloudflare.

1. Vào phần DNS của `apaxsoft.com` (Cloudflare).
2. Tạo hoặc sửa bản ghi: Type `A`, Name `supabase`, Content `62.84.190.239`.
3. Đổi Proxy status từ đám mây cam sang **DNS only** (đám mây xám), rồi Save.
4. Kiểm tra: `nslookup supabase.apaxsoft.com 1.1.1.1` phải ra `62.84.190.239`. Nếu ra `172.67.x.x` hoặc `104.21.x.x` là bản ghi vẫn đang bật proxy hoặc DNS chưa cập nhật.

## Bước 3: SSH key và secrets trên GitHub

GitHub Actions dùng một SSH key riêng chỉ cho việc deploy.

### 3.1 Tạo key (PowerShell trên Windows, dòng bắt đầu bằng `PS C:\`)

1. Tạo cặp key không đặt passphrase: `ssh-keygen -t ed25519 -f $HOME\.ssh\apaxsoft_deploy -N '""' -C "github-deploy"`
2. In public key để copy: `Get-Content $HOME\.ssh\apaxsoft_deploy.pub`

### 3.2 Cài public key lên server (chạy trong phiên SSH vào server)

Dán lệnh sau, thay `<public key>` bằng nội dung ở bước 3.1:

```sh
mkdir -p ~/.ssh && echo '<public key>' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo "62.84.190.239 $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
```

Lệnh in ra một dòng dạng `62.84.190.239 ssh-ed25519 AAAA...`. Giữ dòng đó cho bước 3.4.

### 3.3 Thử đăng nhập bằng key (quay về `PS C:\`)

`ssh -i $HOME\.ssh\apaxsoft_deploy root@62.84.190.239 "echo ok"` phải in `ok` mà không hỏi mật khẩu.

### 3.4 Tạo Environment và secrets

1. Mở `https://github.com/tungpv90/supabase/settings/environments/new`, ô Name gõ `apaxsoft`, bấm **Configure environment**.
2. Mục **Environment secrets**, bấm **Add environment secret**, thêm hai secret:

| Name                 | Giá trị                                                                                                                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEPLOY_SSH_KEY`     | Toàn bộ private key: chạy `Get-Content $HOME\.ssh\apaxsoft_deploy -Raw \| Set-Clipboard` rồi Ctrl+V. Nội dung bắt đầu `-----BEGIN OPENSSH PRIVATE KEY-----` và kết thúc `-----END OPENSSH PRIVATE KEY-----` |
| `DEPLOY_KNOWN_HOSTS` | Dòng `62.84.190.239 ssh-ed25519 AAAA...` lấy ở bước 3.2                                                                                                                                                     |

3. Nếu không đăng nhập bằng user `root`, thêm Environment variable `DEPLOY_USER` với tên user tương ứng.
4. Vào tab **Actions** của repo. Nếu có nút **I understand my workflows, go ahead and enable them**, bấm vào.

Không bao giờ dán private key vào chat, email hay file trong repo.

## Bước 4: Cấu hình nginx trong aaPanel

nginx của aaPanel giữ cổng 80 và 443 cho các trang khác, nên Supabase chỉ mở cổng nội bộ `127.0.0.1:18000` và nginx chuyển tiếp vào đó. Không tắt nginx và không đổi cấu hình các trang khác.

1. Đăng nhập aaPanel, vào **Website**, bấm **Add site**.
2. Domain: `supabase.apaxsoft.com`. Chọn PHP là **Static / Pure static**, không cần tạo database. Bấm **Submit**.
3. Mở site vừa tạo, vào tab **SSL**, chọn **Let's Encrypt**, tick tên miền, bấm **Apply**. Bước này chỉ thành công khi DNS đã trỏ đúng (bước 2). Sau khi cấp xong, bật **Force HTTPS**.
4. Vào tab **Reverse proxy**, bấm **Add reverse proxy**, điền:

| Ô           | Giá trị                       |
| ----------- | ----------------------------- |
| Proxy name  | `supabase`                    |
| Target URL  | `http://127.0.0.1:18000`      |
| Send domain | `$host`                       |
| WebSocket   | Bật nếu có (cần cho Realtime) |

5. Bấm **Submit**.

## Bước 5: Chạy deploy và kiểm tra

Sau khi xong bước 1 đến 4 và code đã nằm trên `master`, deploy chạy tự động khi push và có thể chạy tay bất cứ lúc nào.

1. Mở `https://github.com/tungpv90/supabase/actions`, chọn **Deploy to supabase.apaxsoft.com** ở cột trái.
2. Bấm **Run workflow**, chọn nhánh `master`, bấm **Run workflow** màu xanh.
3. Workflow có hai job. **Build Studio image** build image Studio và đẩy lên GHCR, lần đầu khoảng 15 đến 30 phút, các lần sau nhanh hơn nhờ cache. **Deploy** đồng bộ file, chạy script trên server rồi kiểm tra gateway.
4. Khi cả hai job xanh, mở `https://supabase.apaxsoft.com`. Trình duyệt hỏi tài khoản: user `supabase`, mật khẩu lấy ở phần Vận hành bên dưới.

Kiểm tra nhanh trên server: `cd /opt/supabase && docker compose ps` phải thấy các service ở trạng thái `healthy`. Kiểm tra gateway: `curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18000/auth/v1/health` trả `401` là bình thường (gateway đang yêu cầu API key).

## Vận hành hằng ngày

Mọi lệnh dưới đây chạy trên server, sau khi `ssh -i $HOME\.ssh\apaxsoft_deploy root@62.84.190.239` và `cd /opt/supabase`.

| Việc cần làm                                       | Lệnh                                          |
| -------------------------------------------------- | --------------------------------------------- |
| Xem mật khẩu dashboard, mật khẩu Postgres, API key | `sh run.sh secrets`                           |
| Xem trạng thái các service                         | `sh run.sh status`                            |
| Xem log tất cả service hoặc một service            | `sh run.sh logs` hoặc `sh run.sh logs studio` |
| Khởi động lại một service                          | `sh run.sh restart studio`                    |
| Dừng toàn bộ stack                                 | `sh run.sh stop`                              |
| Khởi động lại toàn bộ stack                        | `sh run.sh start`                             |

**Cập nhật:** push code lên `master`, deploy tự chạy. Workflow chỉ tự chạy khi thay đổi nằm trong `docker/`, `deploy/apaxsoft/`, `apps/studio/`, `packages/`, `patches/` hoặc `pnpm-lock.yaml`.

**Rollback Studio:** mỗi lần deploy đánh thẻ image bằng commit SHA, dạng `ghcr.io/tungpv90/studio:<sha>`. Để quay lại bản cũ, chạy lại workflow từ commit cũ hoặc sửa `STUDIO_IMAGE` trong `/opt/supabase/.env` rồi chạy `docker compose up -d studio`.

**Sao lưu:** dữ liệu Postgres nằm ở `/opt/supabase/volumes/db/data`, file cấu hình và mật khẩu ở `/opt/supabase/.env`. Workflow không bao giờ ghi đè hai thứ này. Hãy sao lưu định kỳ cả hai ra nơi khác (ví dụ `docker compose exec db pg_dumpall -U postgres > backup.sql`) và thử khôi phục ít nhất một lần.

## Xử lý sự cố thường gặp

| Hiện tượng                                                               | Nguyên nhân                                                                           | Cách xử lý                                                                                            |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `Get-Content: command not found` hoặc `Set-Clipboard: command not found` | Đang gõ lệnh Windows trong phiên SSH (dòng `root@...#`)                               | Gõ `exit` đến khi thấy `PS C:\...`, rồi chạy lại                                                      |
| `Identity file ... not accessible`                                       | Chưa tạo SSH key hoặc sai đường dẫn                                                   | Chạy lại `ssh-keygen` ở bước 3.1                                                                      |
| `Permission denied (publickey)` khi SSH bằng key                         | Public key chưa có trong `~/.ssh/authorized_keys` trên server                         | Làm lại bước 3.2                                                                                      |
| `failed to bind host port 0.0.0.0:80/tcp: address already in use`        | nginx của aaPanel đang giữ cổng 80 và 443                                             | Đã xử lý bằng thiết kế hiện tại (không dùng Caddy, gateway chỉ mở `127.0.0.1:18000`). Không tắt nginx |
| Job Deploy lỗi ở bước Configure SSH hoặc Sync files                      | Secret `DEPLOY_SSH_KEY` hoặc `DEPLOY_KNOWN_HOSTS` sai, thiếu hoặc nằm sai Environment | Kiểm tra hai secret nằm trong Environment `apaxsoft`, dán lại đầy đủ                                  |
| `rsync: command not found`                                               | Server chưa cài rsync                                                                 | `apt-get install -y rsync`                                                                            |
| Job Build Studio image lỗi hết bộ nhớ                                    | Runner thiếu RAM khi build                                                            | Chạy lại job; nếu lặp lại, giảm `max-old-space-size` trong `apps/studio/Dockerfile`                   |
| `https://supabase.apaxsoft.com` báo lỗi chứng chỉ hoặc 502               | Chưa cấp SSL, DNS vẫn qua proxy Cloudflare, hoặc chưa tạo reverse proxy               | Làm lại bước 2 và bước 4; kiểm tra `docker compose ps`                                                |
| Bước Check public URL có cảnh báo vàng                                   | Gateway chạy nhưng URL công khai chưa thông                                           | Không làm deploy thất bại; làm bước 4 rồi chạy lại                                                    |
| Realtime không kết nối được                                              | Reverse proxy chưa bật WebSocket                                                      | Bật WebSocket trong cấu hình reverse proxy của aaPanel                                                |

## Bảo mật

Mật khẩu và key của Supabase được sinh ngẫu nhiên ngay lần deploy đầu và chỉ nằm trong `/opt/supabase/.env` trên server, không đi qua GitHub.

- **Chặn cổng Postgres trên internet.** Docker mở cổng 5432 và 6543 ra ngoài và `ufw` không chặn được. Hãy chặn hai cổng này ở firewall của nhà cung cấp server hoặc trong aaPanel (Security), trừ khi cần kết nối từ xa.
- **Lưu mật khẩu đúng chỗ.** Lưu `DASHBOARD_PASSWORD`, `POSTGRES_PASSWORD` và các API key trong trình quản lý mật khẩu. Không gửi vào chat, email hay commit vào repo.
- **SSH key deploy chỉ dùng cho deploy.** Nếu nghi ngờ bị lộ, xóa dòng `github-deploy` trong `/root/.ssh/authorized_keys`, tạo key mới và cập nhật secret `DEPLOY_SSH_KEY`.
- **Fork của `supabase/supabase`.** Khi sync từ upstream có thể gặp xung đột ở thư mục `docker/`. Xem kỹ trước khi merge và chạy lại deploy sau đó.
