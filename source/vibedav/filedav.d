/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 25, 2015
 * License: Subject to the	 terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.filedav;

import vibedav.base;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.utils.dictionarylist;
import vibe.stream.stdio;
import vibe.stream.memory;
import vibe.utils.memory;

import std.conv : to;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.string;
import std.stdio;
import std.typecons;
import std.uri;
import std.uuid;
import std.algorithm.comparison : max;

import tested: testName = name;

string stripSlashes(string path) {
	return path.stripBeginSlashes.stripEndSlasshes;
}

string stripBeginSlashes(string path) {
	if(path.length > 0 && path[0] == '/')
		path = path[1..$];

	if(path.length > 1 && path[0..2] == "./")
		path = path[2..$];

	return path;
}

string stripEndSlasshes(string path) {
	if(path.length > 0 && path[path.length-1] == '/')
		path = path[0..$-1];

	return path;
}

/// Compute a file etag
string eTag(string path) {
	import std.digest.crc;
	import std.stdio;

	string fileHash = path;

	if(!path.isDir) {
		auto f = File(path, "r");
		foreach (ubyte[] buffer; f.byChunk(4096)) {
			ubyte[4] hash = crc32Of(buffer);
			fileHash ~= crcHexString(hash);
		}
	}

	fileHash ~= path.lastModified.toISOExtString ~ path.contentLength.to!string;

	auto etag = hexDigest!MD5(path ~ fileHash);
	return etag.to!string;
}

SysTime lastModified(string path) {
	FileInfo dirent = getFileInfo(path);
	return dirent.timeModified.toUTC;
}

SysTime creationDate(string path) {
	FileInfo dirent = getFileInfo(path);
	return dirent.timeCreated.toUTC;
}

ulong contentLength(string path) {
	FileInfo dirent = getFileInfo(path);
	return dirent.size;
}

FileStream toStream(string path) {
	return openFile(path);
}

bool[string] getFolderContent(string format = "*")(string path, Path rootPath, Path rootUrl) {
	bool[string] list;
	rootPath.endsWithSlash = true;
	string strRootPath = rootPath.toString;

	auto p = Path(path);
	p.endsWithSlash = true;
	path = p.toString;

	enforce(path.isDir);
	enforce(strRootPath.length <= path.length);
	enforce(strRootPath == path[0..strRootPath.length]);

	auto fileList = dirEntries(path, format, SpanMode.shallow);

	foreach(file; fileList) {
		auto filePath = rootUrl ~ file[strRootPath.length..$];
		filePath.endsWithSlash = false;

		if(file.isDir)
			list[filePath.toString] = true;
		else
			list[filePath.toString] = false;
	}

	return list;
}

Path getFilePath(Path baseUrlPath, Path basePath, URL url) {
	string path = url.path.toString.stripSlashes;
	string filePath;

	filePath = path[baseUrlPath.toString.length..$];

	return basePath ~ filePath;
}

@testName("Basic getFilePath")
unittest {
	auto path = getFilePath(Path("test/"), Path("/base/"), URL("http://127.0.0.1/test/file.txt"));
	assert(path.toString == "/base/file.txt");
}

class DirectoryResourcePlugin : IDavResourcePlugin {
	private {
		Path baseUrlPath;
		Path basePath;
	}

	this(Path baseUrlPath, Path basePath) {
		this.baseUrlPath = baseUrlPath;
		this.basePath = basePath;
	}

	Path filePath(URL url) {
		return getFilePath(baseUrlPath, basePath, url);
	}

	pure nothrow {
		bool canSetContent(URL url) {
			return false;
		}

		bool canGetStream(URL url) {
			return false;
		}

		bool canGetProperty(URL url, string name) {
			return false;
		}

		bool canSetProperty(URL url, string name) {
			return false;
		}

		bool canRemoveProperty(URL url, string name) {
			return false;
		}
	}

	bool[string] getChildren(URL url) {
		auto nativePath = filePath(url).toString;
		return getFolderContent!"*"(nativePath, basePath, baseUrlPath);
	}

	void setContent(URL url, const ubyte[] content) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set directory stream.");
	}

	void setContent(URL url, InputStream content, ulong size) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set directory stream.");
	}

	InputStream stream(URL url) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get directory stream.");
	}

	void copyPropertiesTo(URL source, URL destination) {

	}

	DavProp property(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
	}

	HTTPStatus setProperty(URL url, string name, DavProp prop) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set property.");
	}

	HTTPStatus removeProperty(URL url, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't remove property.");
	}

	pure nothrow @property {
		string name() {
			return "DirectoryResourcePlugin";
		}
	}
}

class FileResourcePlugin : IDavResourcePlugin {
	private {
		Path baseUrlPath;
		Path basePath;
	}

	this(Path baseUrlPath, Path basePath) {
		this.baseUrlPath = baseUrlPath;
		this.basePath = basePath;
	}

	Path filePath(URL url) {
		return getFilePath(baseUrlPath, basePath, url);
	}

	bool canSetContent(URL url) {
		auto filePath = filePath(url).toString;
		return filePath.exists;
	}


	bool canGetStream(URL url) {
		return canSetContent(url);
	}

	bool canGetProperty(URL url, string name) {
		return false;
	}

	bool canSetProperty(URL url, string name) {
		return false;
	}

	bool canRemoveProperty(URL url, string name) {
		return false;
	}

	bool[string] getChildren(URL url) {
		bool[string] list;
		return list;
	}

	void setContent(URL url, const ubyte[] content) {
		auto filePath = filePath(url).toString;
		std.stdio.write(filePath, content);
	}

	void setContent(URL url, InputStream content, ulong size) {
		auto nativePath = filePath(url).toString;

		auto tmpPath = nativePath ~ ".tmp";
		auto tmpFile = File(tmpPath, "w");

		while(!content.empty) {
			auto leastSize = content.leastSize;
			ubyte[] buf;
			buf.length = leastSize;
			content.read(buf);
			tmpFile.rawWrite(buf);
		}

		tmpFile.flush;

		std.file.copy(tmpPath, nativePath);
		std.file.remove(tmpPath);
	}

	InputStream stream(URL url) {
		auto nativePath = filePath(url).toString;
		return nativePath.toStream;
	}

	DavProp property(DavResource resource, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't get property.");
	}

	void copyPropertiesTo(URL source, URL destination) {

	}

	HTTPStatus setProperty(URL url, string name, DavProp prop) {
		throw new DavException(HTTPStatus.internalServerError, "Can't set property.");
	}

	HTTPStatus removeProperty(URL url, string name) {
		throw new DavException(HTTPStatus.internalServerError, "Can't remove property.");
	}

	pure nothrow @property {
		string name() {
			return "FileResourcePlugin";
		}
	}
}

/// File Dav impplementation
class FileDav : IDavPlugin {

	private {
		IDav _dav;
		Path baseUrlPath;
		Path basePath;
	}

	this(IDav dav, Path baseUrlPath, Path basePath) {
		_dav = dav;
		this.baseUrlPath = baseUrlPath;
		this.basePath = basePath;
	}

	private {
		void setResourceProperties(DavResource resource) {
			string path = filePath(resource.url).toString;

			resource.creationDate = creationDate(path);
			resource.lastModified = lastModified(path);
			resource.eTag = eTag(path);
			resource.contentType = getMimeTypeForFile(path);
			resource.contentLength = contentLength(path);

			if(path.isDir) {
				resource.resourceType ~= "collection:DAV:";
				resource.registerPlugin(new DirectoryResourcePlugin(baseUrlPath, basePath));
			} else
				resource.registerPlugin(new FileResourcePlugin(baseUrlPath, basePath));

			resource.registerPlugin(new ResourceCustomProperties);
			resource.registerPlugin(new ResourceBasicProperties);
		}
	}

	string[] support() {
		return ["1", "2", "3"];
	}

	Path filePath(URL url) {
		return getFilePath(baseUrlPath, basePath, url);
	}

	bool exists(URL url) {
		auto filePath = filePath(url);

		return filePath.toString.exists;
	}

	bool canCreateResource(URL url) {
		return !exists(url);
	}

	bool canCreateCollection(URL url) {
		return !exists(url);
	}

	void removeResource(URL url, IDavUser user = null) {
		if(!exists(url))
			throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");

		auto filePath = filePath(url).toString;

		if(filePath.isDir)
			filePath.rmdirRecurse;
		else
			filePath.remove;

	}

	DavResource getResource(URL url, IDavUser user = null) {
		if(!exists(url))
			throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");

		auto filePath = filePath(url);

		DavResource resource = new DavResource(_dav, url);
		setResourceProperties(resource);

		return resource;
	}

	DavResource createResource(URL url) {
		auto filePath = filePath(url).toString;

		File(filePath, "w");

		return getResource(url);
	}

	DavResource createCollection(URL url) {
		auto filePath = filePath(url);

		if(filePath.toString.exists)
			throw new DavException(HTTPStatus.methodNotAllowed, "Resource already exists.");

		filePath.toString.mkdirRecurse;

		return getResource(url);
	}

	@property {
		string name() {
			return "FileDav";
		}

		IDav dav() {
			return _dav;
		}
	}
}

IDav serveFileDav(URLRouter router, string rootUrl, string rootPath, IDavUserCollection userCollection = null) {
	rootUrl = rootUrl.stripSlashes;
	rootPath = rootPath.stripSlashes;

	auto dav = new Dav(rootUrl);
	auto fileDav = new FileDav(dav, Path(rootUrl), Path(rootPath));
	dav.registerPlugin(fileDav);

	dav.userCollection = userCollection;

	if(rootUrl != "") rootUrl = "/"~rootUrl~"/";

	router.any(rootUrl ~ "*", serveDav(dav));

	return dav;
}
