# ---------- Build Stage ----------
FROM dart:stable AS build

WORKDIR /app

# Copy pubspec first (cache-friendly)
COPY pubspec.* ./

# Get dependencies
RUN dart pub get

# Copy all source code including servers, services, and models
COPY servers ./servers
COPY services ./services
COPY models ./models

# Compile the Dart server to executable
RUN dart compile exe servers/signals_server.dart -o bin/signals_server_exec

# ---------- Runtime Stage ----------
FROM debian:stable-slim

WORKDIR /app

# Copy compiled executable from build stage
COPY --from=build /app/bin/signals_server_exec ./bin/signals_server_exec

# Copy any required config or data files if needed (optional)
# COPY config ./config

# Make sure executable has execution permissions
RUN chmod +x ./bin/signals_server_exec

# Expose the port Railway expects
ENV PORT=8080
EXPOSE 8080

# Run the executable in foreground
CMD ["./bin/signals_server_exec"]