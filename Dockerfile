# ---------- Build Stage ----------
FROM dart:stable AS build
WORKDIR /app

# Copy pubspec first (caching ya tabaka - layer caching - haraka zaidi
# kwa build zinazofuata endapo dependencies hazijabadilika)
COPY pubspec.* ./

# Install dependencies
RUN dart pub get

# Copy source code
COPY servers ./servers
COPY services ./services
COPY models ./models

# 🔥 CREATE bin folder (IMPORTANT FIX)
RUN mkdir -p bin

# Compile Dart server to executable
RUN dart compile exe servers/signals_server.dart -o bin/signals_server_exec


# ---------- Runtime Stage ----------
FROM debian:stable-slim
WORKDIR /app

# 🚨🚨🚨 FIX YA BUG HALISI (chanzo cha "CERTIFICATE_VERIFY_FAILED:
# unable to get local issuer certificate" wakati wa kuunganisha na
# Deriv API kupitia HTTPS/TLS): 'debian:stable-slim' ni image NDOGO
# KIMAKUSUDI - HAINA 'ca-certificates' (vyeti vya mashirika
# yanayoaminika ya CA) kwa DEFAULT. Bila hivi, Dart HAIWEZI kuthibitisha
# uhalali wa cheti cha SSL/TLS cha 'api.derivws.com' (wala tovuti
# nyingine yoyote ya HTTPS) - ombi LOLOTE la HTTPS/WSS litashindwa
# na hitilafu hii hii, bila kujali code ya Dart ni sahihi kiasi gani.
#
# Sasa: tunasakinisha 'ca-certificates' MOJA KWA MOJA hapa (runtime
# stage - ndipo panapohitajika HASA, kwa kuwa app halisi inaendeshwa
# hapa, si kwenye build stage) - na kufuta cache ya apt baadaye
# ('rm -rf /var/lib/apt/lists/*') kuweka image ndogo iwezekanavyo
# (kanuni ya kawaida ya Docker - epuka kuongeza uzito usio wa lazima).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy executable
COPY --from=build /app/bin/signals_server_exec ./bin/signals_server_exec

# Permission
RUN chmod +x ./bin/signals_server_exec

# Port
ENV PORT=8080
EXPOSE 8080

# Run
CMD ["./bin/signals_server_exec"]