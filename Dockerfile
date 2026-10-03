FROM alpine:3.21

RUN apk add --no-cache \
		dosfstools \
		mtools \
		e2fsprogs \
		p7zip \
		parted \
		advancecomp \
		coreutils \
		util-linux \
		wget \
		zip

VOLUME /build

COPY . /pianoberry/

ENTRYPOINT ["/pianoberry/pianoberry/build"]
