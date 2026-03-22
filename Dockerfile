# ---------- Build Stage ----------
FROM dart:stable AS build

WORKDIR /app

# Copy pubspec first
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

# Copy executable
COPY --from=build /app/bin/signals_server_exec ./bin/signals_server_exec

# Permission
RUN chmod +x ./bin/signals_server_exec

# Port
ENV PORT=8080
EXPOSE 8080

# Run
CMD ["./bin/signals_server_exec"]