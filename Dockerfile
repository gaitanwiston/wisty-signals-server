# ---------- Build Stage ----------
FROM dart:stable AS build

# Set working directory inside container
WORKDIR /app

# Copy pubspec first (cache-friendly)
COPY pubspec.* ./

# Install dependencies
RUN dart pub get

# Copy all source code (servers, services, models)
COPY servers ./servers
COPY services ./services
COPY models ./models

# Optional: copy config or environment files if you have any
# COPY config ./config
# COPY .env ./.env

# Compile Dart server to executable
RUN dart compile exe servers/signals_server.dart -o bin/signals_server_exec

# ---------- Runtime Stage ----------
FROM debian:stable-slim

WORKDIR /app

# Copy compiled executable from build stage
COPY --from=build /app/bin/signals_server_exec ./bin/signals_server_exec

# Ensure executable has permission
RUN chmod +x ./bin/signals_server_exec

# Expose the port Railway expects
ENV PORT=8080
EXPOSE 8080

# Run the server in foreground
CMD ["./bin/signals_server_exec"]