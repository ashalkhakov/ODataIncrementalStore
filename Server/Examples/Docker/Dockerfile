# An application of its own, in an image of its own: built in odatakit-sdk,
# run on odatakit-runtime (Docker/Dockerfile builds both).
#
#   docker build -f Server/Examples/Docker/Dockerfile -t catalog-server Server/Examples
#   docker run -p 8080:8080 -e OIS_SERVICE_ROOT=http://localhost:8080/odata/ catalog-server

FROM odatakit-sdk AS build
COPY Docker/GNUmakefile CatalogServer.m /app/
RUN make -C /app

FROM odatakit-runtime
COPY --from=build /app/obj/catalog-server /usr/local/bin/catalog-server
RUN useradd --system --home-dir /var/lib/catalog --create-home catalog
ENV OIS_MODEL=/usr/local/share/ois-serve/Catalog.momd \
    OIS_STORE_TYPE=SQLite \
    OIS_STORE_URL=/var/lib/catalog/catalog.sqlite \
    OIS_PORT=8080 \
    OIS_LOCALHOST=NO \
    OIS_ACCESS_LOG=json \
    OIS_ADMIN_PORT=9090 \
    OIS_ADMIN_LOCALHOST=NO \
    HOME=/var/lib/catalog
USER catalog
VOLUME /var/lib/catalog
EXPOSE 8080 9090
ENTRYPOINT ["/usr/local/bin/ois-env", "catalog-server"]
