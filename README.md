<div id="top"></div>

<!-- FREQSTART -->
# FREQSTART v3.0.1

See what has been changed: <a href="#changelog">Changelog</a>

## Setup & Docker-Manager for Freqtrade

Freqstart simplifies the use of Freqtrade with Docker. Including a simple setup guide for Freqtrade,
configurations and FreqUI with a secured SSL proxy for IP or domain. Freqstart also automatically
installs implemented strategies based on Docker Compose files and detects necessary updates.

Freqstart is the combined public knowledge, based on best practice solutions, to run Freqtrade
in the most secure environment possible. Every step can be done manually and even if you decide
to remove Freqstart, you can start and stop your project files with native Docker commands.

IF YOU ARE NOT FAMILIAR WITH FREQTRADE, PLEASE READ THE COMPLETE DOCUMENTATION FIRST ON: [www.freqtrade.io](https://www.freqtrade.io/)

For `Freqstart` related questions, use die github issue list: [open issues](https://github.com/freqstart/freqstart/issues)

For `Freqtrade` related questions, join the official discord: https://discord.gg/g549bRAy

### Features

* `Freqtrade` Guided setup for Docker including the native config generator and creation of "user_data" folder.
* `Docker` Version check of images via manifest using minimal ressources and creating local backups.
* `Prerequisites` Install server prerequisites and upgrades and check for server time sync.
* `FreqUI` Full setup of FreqUI incl. Nginx proxy for secured IP (openssl) or domain (letsencrypt).
* `Binance Proxy` Setup for Binance proxy if you run multiple bots at once incl. reusable config file.
* `Kucoin Proxy` Setup for Kucoin proxy if you run multiple bots at once incl. reusable config file.
* `Strategies` Automated installation of implemented strategies like NostalgiaForInfinity incl. updates every 12h.

### Strategies

The following list of implemented strategies is in alphabetical order and does not represent any recommendation:

* `Cenderawasih_3` (Author: stash86, Source: https://github.com/stash86/MultiMA_TSL/)
* `Cenderawasih_3_kucoin` (Author: stash86, Source: https://github.com/stash86/MultiMA_TSL/)
* `DoesNothingStrategy` (Author: Gert Wohlgemuth)
* `MultiMA_TSL` (Author: stash86, Source: https://github.com/stash86/MultiMA_TSL/)
* `MultiMA_TSL5` (Author: stash86, Source: https://github.com/stash86/MultiMA_TSL/)
* `NASOSv4` (Author: Rallipanos, pluxury)
* `NASOSv5` (Author: Rallipanos, pluxury)
* `NostalgiaForInfinityX` (Author: iterativ, Source: https://github.com/iterativv/NostalgiaForInfinity)

Help expanding the strategies list and include config files if possible: [freqstart_strategies.json](https://raw.githubusercontent.com/freqstart/freqstart/stable/freqstart_strategies.json)

Optional: Add freqstart_strategies_custom.json to script root and add your own URLs from other sources.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- GETTING STARTED -->
## Getting Started

Freqstart provides an interactive setup guide for server security, Freqtrade incl. config creation, FreqUI, Binance- & Kucoin-Proxy routines.

### Prerequisites

Freqstart installs server packages and configurations tailored to the needs of Freqtrade and may overwrite existing installations and configurations. It is recommended to set it up in a new and clean environment!

Packages: curl, jq, docker-ce, docker-compose, docker-ce-rootless-extras, systemd-container, uidmap, dbus-user-session

### Recommended VPS

If you take crypto bot trading seriously never use a VPS with only one core. Freqtrade may not utilize multithread but with CPU-heavy strategies like NFIX, your VPS would be locked up nearly 100% every time. Also, it is recommended to add 1 CPU core per bot. So if you run 3 different strategies, you should have at least 4 CPU cores to have some buffer for other system tasks. Additionally install bashtop ($ sudo apt install bashtop), set the timing to 30.000ms, and look how long it takes your VPS to finish the calculation of a new trading candle from 100% to under 20% within 10 bars (= 5 minutes) per core. A good benchmark for NFIX would be 2 minutes, which are 4 bars. Anything higher or permanent above 90% and you risk losing money or never getting any trading entries. Don't be cheap on your way to the moon or you probably end up in goblin town anyways.

HostHatch (NVMe 4GB & 16GB / Hong Kong / Ubuntu LTS): [hosthatch.com](https://cloud.hosthatch.com/a/2781)

Vultr (Intel High Frequency / Tokyo / Ubuntu LTS): [vultr.com](https://www.vultr.com/?ref=9122650-8H)

### Setup

1. Clone the repo
   ```sh
   git clone https://github.com/freqstart/freqstart.git
   ```
2. Change directory to `freqstart`
   ```sh
   cd ~/freqstart
   ```
3. Make `freqstart.sh` executable
   ```sh
   sudo chmod +x freqstart.sh
   ```
4. Setup `freqstart`
   ```sh
   ./freqstart.sh
   ```
   
### Start `Freqtrade` docker compose projects

   ```sh
   freqstart
   ```

### Stop `Freqtrade` docker compose projects

   ```sh
   freqstart --quit
   ```

### Reset to stop and remove all docker images, containers and networks

   ```sh
   freqstart --reset
   ```

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- EXAMPLE PROJECT -->
## Project

With Freqstart you are no longer bound to a single docker-compose.yml and can freely structure and link your Freqtrade bots.

* Have multiple container (services) in one project file
* Have a single container (service) in multiple project files
* Have multiple container (services) in multiple project files

### Example Docker Project

* Project file based on NostalgiaForInfinityX and Binance (BUSD) with Proxy enabled.

   ```yml
   version: '3'
   services:
     example_dryrun:
       image: freqtradeorg/freqtrade:stable
       volumes:
         - "./user_data:/freqtrade/user_data"
       command: >
         trade
         --dry-run
         --db-url sqlite:////freqtrade/user_data/example_dryrun.sqlite
         --logfile /freqtrade/user_data/logs/example_dryrun.log
         --strategy NostalgiaForInfinityX
         --strategy-path /freqtrade/user_data/strategies/NostalgiaForInfinityX
         --config /freqtrade/user_data/config.json
         --config /freqtrade/user_data/strategies/NostalgiaForInfinityX/pairlist-volume-binance-busd.json
         --config /freqtrade/user_data/strategies/NostalgiaForInfinityX/blacklist-binance.json
         --config /freqtrade/user_data/freqstart_proxy_binance.json
   ```

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- ROADMAP -->
## Roadmap

See the [open issues](https://github.com/freqstart/freqstart/issues) for a full list of proposed features (and known issues).

### Changelog

`v3.0.1`
* Improved download routine.
* Implemented script update option.

`v3.0.0`
* Granted the permission from original author to continue further development.

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- SUPPORT -->
## Support

You can contribute by donating to the following wallets:

* `BTC` 1M6wztPA9caJbSrLxa6ET2bDJQdvigZ9hZ
* `ETH` 0xb155f0F64F613Cd19Fb35d07D43017F595851Af5
* `BSC` 0xb155f0F64F613Cd19Fb35d07D43017F595851Af5

<p align="right">(<a href="#top">back to top</a>)</p>

<!-- DISCLAIMER -->
## Disclaimer
 
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.