/* This file is part of the Joshua Machine Translation System.
 * 
 * Joshua is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1
 * of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free
 * Software Foundation, Inc., 59 Temple Place, Suite 330, Boston,
 * MA 02111-1307 USA
 */
package joshua.util.io;

import java.util.Iterator;
import java.util.NoSuchElementException;
import java.lang.UnsupportedOperationException;


/**
 * This class provides a null-object Reader. This is primarily
 * useful for when you may or may not have a reader, and you don't
 * want to check for null all the time. All operations are no-ops.
 *
 * @author wren ng thornton <wren@users.sourceforge.net>
 * @version $LastChangedDate: 2009-03-26 15:06:57 -0400 (Thu, 26 Mar 2009) $
 */
public class NullReader<E> implements Reader<E> {
	
//===============================================================
// Constructors and destructors
//===============================================================
	
	// TODO: use static factory method and singleton?
	public NullReader() { }
	
	public void close() throws IOException { }
	
	
//===============================================================
// Reader
//===============================================================
	
	/** Always returns true. */
	public boolean ready() { return true; }
	
	/** Always returns null. */
	public E readLine() throws IOException { return null; }
	
	
//===============================================================
// Iterable -- because sometimes Java can be very stupid
//===============================================================
	
	public Iterator<E> iterator() { return this; }
	
	
//===============================================================
// Iterator
//===============================================================
	
	/** Always returns false. */
	public boolean hasNext() { return false; }
	
	/** Always throws NoSuchElementException. */
	public E next() throws NoSuchElementException {
		throw new NoSuchElementException();
	}
	
	/** Unsupported. */
	public void remove() throws UnsupportedOperationException {
		throw new UnsupportedOperationException();
	}
}
